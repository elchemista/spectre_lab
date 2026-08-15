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

  test "exposes optional capabilities and stable reconciliation outcomes" do
    capabilities =
      StreamAdapter.capabilities(:fixture,
        cost_usage: true,
        reconcile_result: :pending
      )

    assert MapSet.subset?(MapSet.new([:cost_usage, :reconcile]), capabilities)

    for {configured, expected} <- [
          {{:ok, %{reply_text: "done"}}, {:ok, %{reply_text: "done"}}},
          {:pending, :pending},
          {:not_found, :not_found},
          {{:error, :offline}, {:error, :offline}},
          {:invalid, {:error, :invalid_lab_stream_reconcile_result}}
        ] do
      assert StreamAdapter.reconcile(descriptor(), "request", reconcile_result: configured) ==
               expected
    end

    assert StreamAdapter.reconcile(descriptor(), "request", []) == :not_found
  end

  test "enforces pull credit, fixture identity, and owned bounds" do
    script = StreamScript.new!([:stall])
    opts = adapter_opts(script, delivery: :external)

    assert {:ok, state, _metadata} = StreamAdapter.open(descriptor(), opts)
    assert {:ok, waiting} = StreamAdapter.request_transport_item(state)

    assert {:error, :lab_stream_demand_already_outstanding} =
             StreamAdapter.request_transport_item(waiting)

    assert {:error, :lab_stream_fixture_mismatch, ^waiting} =
             StreamAdapter.handle_transport(
               {:spectre_lab_stream_item, waiting.token, 99, :stall},
               waiting
             )

    assert {:error, :lab_stream_stall_delivered, delivered} =
             StreamAdapter.handle_transport(
               {:spectre_lab_stream_item, waiting.token, 1, :stall},
               waiting
             )

    assert {:error, :lab_stream_script_exhausted} =
             StreamAdapter.request_transport_item(delivered)

    assert {:ignore, ^delivered} = StreamAdapter.handle_transport(:unrelated, delivered)

    small = {:spectre_lab_stream_bound, delivered.token, :transport_chunk, "ok"}
    assert {:ok, [], ^delivered} = StreamAdapter.handle_transport(small, delivered)
  end

  test "fails closed for every adapter-owned option" do
    script = StreamScript.text!("options")
    bounds = adapter_opts(script)

    assert {:error, :forced_open_failure} =
             StreamAdapter.open(
               descriptor(),
               Keyword.put(bounds, :open_error, :forced_open_failure)
             )

    assert {:error, :missing_lab_stream_script} =
             StreamAdapter.open(descriptor(), Keyword.delete(bounds, :script))

    assert {:error, :duplicate_lab_stream_script} =
             StreamAdapter.open(descriptor(), [{:script, script} | bounds])

    assert {:error, :invalid_lab_stream_cursor} =
             StreamAdapter.resume(descriptor(), {:spectre_lab, 99}, bounds)

    assert {:error, :invalid_lab_stream_delivery} =
             StreamAdapter.open(descriptor(), Keyword.put(bounds, :delivery, :callback))

    assert {:error, :invalid_lab_stream_cancel_reply} =
             StreamAdapter.open(descriptor(), Keyword.put(bounds, :cancel_reply, :ignored))

    assert {:error, :invalid_lab_stream_metadata} =
             StreamAdapter.open(descriptor(), Keyword.put(bounds, :metadata, self()))
  end

  test "keeps explicit cursors and reduces cancellation reasons for observers" do
    event = ProviderEvent.delta("x", provider_sequence: 0, cursor: {:provider, 7})
    script = StreamScript.new!([event])
    opts = adapter_opts(script, observer: self())

    assert {:ok, state, _metadata} = StreamAdapter.open(descriptor(), opts)
    assert {:ok, waiting} = StreamAdapter.request_transport_item(state)
    assert_receive {:spectre_lab_stream_item, token, 1, item}

    assert {:ok, [%ProviderEvent{cursor: {:provider, 7}}], delivered} =
             StreamAdapter.handle_transport(
               {:spectre_lab_stream_item, token, 1, item},
               waiting
             )

    assert :ok = StreamAdapter.cancel(delivered, {:shutdown, :owner, :detail})
    assert_receive {:spectre_lab_stream, {:cancelled, _session, :shutdown}}

    assert :ok = StreamAdapter.cancel(delivered, %{private: "reason"})
    assert_receive {:spectre_lab_stream, {:cancelled, _session, :error}}
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

  defp adapter_opts(script, opts \\ []) do
    Keyword.merge(
      [
        script: script,
        spectre_bounds: [
          max_transport_chunk_bytes: 256,
          max_parser_residual_bytes: 256
        ]
      ],
      opts
    )
  end

  defp collect_observer_messages(messages) do
    receive do
      {:spectre_lab_stream, event} -> collect_observer_messages([event | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
