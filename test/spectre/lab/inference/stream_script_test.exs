defmodule SpectreLabInferenceStreamScriptTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.ProviderEvent
  alias Spectre.Lab.Inference.StreamScript

  test "builds globally sequenced cumulative text fixtures" do
    assert {:ok, script} =
             StreamScript.text("hello",
               chunks: ["he", "ll", "o"],
               input_tokens: 2,
               output_tokens: 3,
               cost: 0.3,
               duration_ms: 9,
               usage_quality: :provider
             )

    events = events(script)
    assert Enum.map(events, & &1.provider_sequence) == Enum.to_list(0..5)

    assert events
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == "hello"

    assert Enum.map(events, & &1.kind) == [
             :started,
             :delta,
             :delta,
             :delta,
             :usage,
             :completed
           ]

    output_tokens = Enum.map(events, & &1.usage.output_tokens)
    assert output_tokens == Enum.sort(output_tokens)
    assert List.last(output_tokens) == 3
    assert List.last(events).usage.total_tokens == 5
  end

  test "allows network-like chunks to split a UTF-8 codepoint" do
    text = "A😀B"
    <<first::binary-size(2), second::binary-size(2), third::binary>> = text

    assert {:ok, script} = StreamScript.text(text, chunks: [first, second, third])

    assert script
           |> events()
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == text
  end

  test "validates custom items and keeps transport controls explicit" do
    started = ProviderEvent.new(:started, provider_sequence: 0)

    assert {:ok, %StreamScript{}} =
             StreamScript.new([[started], :stall, {:transport_error, :offline}])

    assert {:error, {:invalid_lab_stream_script_item, 0, :empty_event_batch}} =
             StreamScript.new([[]])

    assert {:error, {:invalid_lab_stream_script_item, 0, :invalid_item}} =
             StreamScript.new([{:transport_error, nil}])
  end

  test "keeps text construction options closed and unambiguous" do
    assert {:error, :duplicate_lab_stream_text_options} =
             StreamScript.text("x", chunk_size: 1, chunk_size: 2)

    assert {:error, :unknown_lab_stream_text_options} =
             StreamScript.text("x", private_callback: fn -> :ok end)

    assert {:error, :invalid_lab_stream_chunks} =
             StreamScript.text("hello", chunks: ["different"])

    assert {:error, :invalid_lab_stream_chunk_size} =
             StreamScript.text("hello", chunk_size: 0)

    assert_raise ArgumentError, ~r/invalid Lab text stream/, fn ->
      StreamScript.text!("hello", chunks: [])
    end
  end

  test "produces exact external messages and rejects stalls for conformance" do
    script = StreamScript.text!("ok", chunk_size: 1)
    assert {:ok, messages} = StreamScript.conformance_messages(script, :token)
    assert length(messages) == length(script.items)

    assert Enum.with_index(messages, 1)
           |> Enum.all?(fn
             {{:spectre_lab_stream_item, :token, index, _item}, index} -> true
             _other -> false
           end)

    stalled = StreamScript.new!([:stall])

    assert {:error, :lab_stream_stall_has_no_conformance_message} =
             StreamScript.conformance_messages(stalled, :token)
  end

  test "rejects malformed top-level values and provider events" do
    assert {:error, :invalid_lab_stream_script} = StreamScript.new(:not_a_script)

    assert_raise ArgumentError, ~r/invalid Lab stream script/, fn ->
      StreamScript.new!([:invalid])
    end

    invalid_event = %ProviderEvent{kind: :unknown}

    assert {:error, {:invalid_lab_stream_script_item, 0, :invalid_provider_event_kind}} =
             StreamScript.new([invalid_event])

    assert {:error, {:invalid_lab_stream_script_item, 0, :invalid_provider_event}} =
             StreamScript.new([[123]])
  end

  test "rejects malformed text and supports an empty terminal response" do
    assert {:error, :invalid_lab_stream_text} = StreamScript.text(<<255>>)
    assert {:error, :invalid_lab_stream_text_options} = StreamScript.text(:not_text)
    assert {:error, :invalid_lab_stream_text_options} = StreamScript.text("x", [:not_keyword])
    assert {:error, :invalid_lab_stream_chunks} = StreamScript.text("x", chunks: :invalid)

    assert {:ok, script} = StreamScript.text("")
    assert Enum.map(events(script), & &1.kind) == [:started, :usage, :completed]
    assert List.last(events(script)).usage.output_tokens == 0
    assert List.last(events(script)).usage.cost == 0
  end

  test "reports the exact invalid usage option" do
    for {opts, reason} <- [
          {[input_tokens: -1], :invalid_lab_stream_input_tokens},
          {[output_tokens: -1], :invalid_lab_stream_output_tokens},
          {[cost: -0.01], :invalid_lab_stream_cost},
          {[duration_ms: -1], :invalid_lab_stream_duration},
          {[usage_quality: :guessed], :invalid_lab_stream_usage_quality},
          {[provider_request_id: ""], :invalid_lab_stream_provider_request_id}
        ] do
      assert {:error, ^reason} = StreamScript.text("usage", opts)
    end
  end

  defp events(script) do
    Enum.flat_map(script.items, fn
      {:events, events} -> events
      _control -> []
    end)
  end
end
