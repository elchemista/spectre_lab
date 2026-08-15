defmodule SpectreLabInferenceStreamAdapterTest.Model do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:error, :virtual_stream_must_not_call_complete}
end

defmodule SpectreLabInferenceStreamAdapterTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/stream_prompts"

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :stream_fixture do
    on :STREAM, regex: ~r/stream/i do
      ask(:base)
    end
  end
end

defmodule SpectreLabInferenceStreamAdapterTest do
  use Spectre.Lab.TestCase, async: true

  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.StreamAdapter.Conformance
  alias Spectre.Inference.StreamEvent
  alias Spectre.Instance
  alias Spectre.Lab.Inference.StreamAdapter
  alias Spectre.Lab.Inference.StreamScript
  alias Spectre.Prompt.Plan
  alias Spectre.Result
  alias Spectre.Subject

  @agent SpectreLabInferenceStreamAdapterTest.Agent
  @model SpectreLabInferenceStreamAdapterTest.Model

  test "drives the real lazy Enumerable to its canonical Result", context do
    instance = start_instance(context, "success")
    script = StreamScript.text!("hello from Lab", chunk_size: 3)

    assert {:ok, stream} = start_stream(instance, script, observer: self())
    refute_received {:spectre_lab_stream, {:opened, _session, _cursor}}

    events = Enum.to_list(stream)

    assert_receive {:spectre_lab_stream, {:opened, session, 0}}
    assert_receive {:spectre_lab_stream, {:demand, ^session, 1}}

    assert events
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == "hello from Lab"

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: "hello from Lab"}} =
             List.last(events)
  end

  test "reassembles a codepoint split across pull items", context do
    instance = start_instance(context, "utf8")
    text = "A😀B"
    <<first::binary-size(2), second::binary-size(2), third::binary>> = text
    script = StreamScript.text!(text, chunks: [first, second, third])

    assert {:ok, stream} = start_stream(instance, script)
    events = Enum.to_list(stream)

    assert events
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == text

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: ^text}} =
             List.last(events)
  end

  test "early Enumerable halt cancels the owned provider session", context do
    instance = start_instance(context, "cancel")

    script =
      StreamScript.new!([
        [
          ProviderEvent.new(:started, provider_sequence: 0),
          ProviderEvent.delta("partial", provider_sequence: 1)
        ],
        :stall
      ])

    assert {:ok, stream} = start_stream(instance, script, observer: self())
    assert [_first] = Enum.take(stream, 1)

    assert_receive {:spectre_lab_stream, {:cancelled, _session, :consumer_halted}}
  end

  test "transport errors fail through the core and observer messages stay redacted", context do
    instance = start_instance(context, "failure")

    script =
      StreamScript.new!([
        [ProviderEvent.new(:started, provider_sequence: 0)],
        {:transport_error, {:provider_private_failure, "must-not-leak"}}
      ])

    assert {:ok, stream} = start_stream(instance, script, observer: self())
    events = Enum.to_list(stream)

    assert %StreamEvent{kind: :failed} = List.last(events)

    observer_messages = collect_observer_messages([])
    refute inspect(observer_messages) =~ "must-not-leak"
  end

  test "passes the core stream-adapter conformance including owned bounds" do
    script = StreamScript.text!("conformance", chunk_size: 4)
    token = {:lab, :conformance}
    assert {:ok, messages} = StreamScript.conformance_messages(script, token)

    assert {:ok,
            %{
              transport: :pull,
              events: 6,
              terminal: :completed,
              bound_checks: %{transport_chunk: :enforced, parser_residual: :enforced}
            }} =
             Conformance.run(StreamAdapter, descriptor(), messages,
               adapter_opts: [
                 script: script,
                 delivery: :external,
                 stream_token: token
               ]
             )
  end

  test "resume starts after the durable Lab cursor" do
    script = StreamScript.text!("resume", chunk_size: 3)

    opts = [
      script: script,
      observer: self(),
      spectre_bounds: [
        max_transport_chunk_bytes: 256,
        max_parser_residual_bytes: 256
      ]
    ]

    assert {:ok, state, _metadata} = StreamAdapter.resume(descriptor(), {:spectre_lab, 1}, opts)
    assert {:ok, state} = StreamAdapter.request_transport_item(state)

    assert_receive {:spectre_lab_stream_item, token, 2, item}

    assert {:ok, events, _state} =
             StreamAdapter.handle_transport(
               {:spectre_lab_stream_item, token, 2, item},
               state
             )

    assert Enum.all?(events, &(&1.cursor == {:spectre_lab, 2}))
  end

  test "adapter options fail closed before any fixture is opened" do
    script = StreamScript.text!("invalid")

    assert {:error, :invalid_lab_stream_bounds} =
             StreamAdapter.open(descriptor(), script: script)

    assert {:error, :invalid_lab_stream_observer} =
             StreamAdapter.open(descriptor(),
               script: script,
               observer: :registered_name,
               spectre_bounds: [
                 max_transport_chunk_bytes: 256,
                 max_parser_residual_bytes: 256
               ]
             )

    assert {:error, :invalid_lab_stream_cursor} =
             StreamAdapter.resume(descriptor(), :opaque_provider_cursor, script: script)
  end

  defp start_instance(context, label) do
    {:ok, instance} =
      start_lab_child(
        context,
        {Instance,
         agent: @agent,
         subject:
           Subject.new("lab-stream-#{label}-#{System.unique_integer([:positive, :monotonic])}"),
         idle: false}
      )

    instance
  end

  defp start_stream(instance, script, adapter_opts \\ []) do
    Spectre.stream(instance, "stream this",
      model: @model,
      plan_actions?: false,
      stream_adapter: StreamAdapter,
      stream_adapter_opts: Keyword.put(adapter_opts, :script, script),
      stream_open_timeout: 1_000,
      stream_provider_stall_timeout: 1_000,
      stream_consumer_idle_timeout: 1_000,
      stream_result_timeout: 1_000,
      stream_terminal_retention: 2_000
    )
  end

  defp descriptor do
    %Descriptor{
      id: "lab-stream-conformance",
      purpose: :response_generation,
      plan: %Plan{rendered: "stream"},
      constraints: %Constraints{}
    }
  end

  defp collect_observer_messages(messages) do
    receive do
      {:spectre_lab_stream, event} -> collect_observer_messages([event | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
