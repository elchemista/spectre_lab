defmodule Spectre.Lab.Inference.StreamScript do
  @moduledoc """
  Validated transport script for `Spectre.Lab.Inference.StreamAdapter`.

  A script is finite and caller-owned. Event batches represent one provider
  transport item each, `:stall` consumes one demand without delivering a
  message, and `{:transport_error, reason}` makes the adapter fail that item.
  Lab never converts a synchronous model call into a stream.

  `text/2` builds a correctly ordered text-only response with cumulative usage.
  Custom scripts can use `new/1` to exercise ordering, terminal, UTF-8, budget,
  and recovery behavior through ordinary core `ProviderEvent` values.
  """

  alias Spectre.Inference.ProviderEvent

  @enforce_keys [:items]
  defstruct @enforce_keys

  @text_options [
    :chunk_size,
    :chunks,
    :input_tokens,
    :output_tokens,
    :cost,
    :duration_ms,
    :usage_quality,
    :provider_request_id
  ]

  @type item ::
          {:events, [ProviderEvent.t()]}
          | :stall
          | {:transport_error, term()}
  @type t :: %__MODULE__{items: [item()]}

  @doc "Builds a validated script from provider-event batches and transport controls."
  @spec new([item() | [ProviderEvent.t()] | ProviderEvent.t()] | t()) ::
          {:ok, t()} | {:error, term()}
  def new(%__MODULE__{items: items}), do: new(items)

  def new(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
      case normalize_item(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_lab_stream_script_item, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, %__MODULE__{items: Enum.reverse(normalized)}}
      {:error, _reason} = error -> error
    end
  end

  def new(_items), do: {:error, :invalid_lab_stream_script}

  @doc "Builds a validated script or raises with its stable validation reason."
  @spec new!([item() | [ProviderEvent.t()] | ProviderEvent.t()] | t()) :: t()
  def new!(items) do
    case new(items) do
      {:ok, script} -> script
      {:error, reason} -> raise ArgumentError, "invalid Lab stream script: #{inspect(reason)}"
    end
  end

  @doc "Builds a finite text response split into pull-driven transport items."
  @spec text(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def text(text, opts \\ [])

  def text(text, opts) when is_binary(text) and is_list(opts) do
    with true <- String.valid?(text),
         :ok <- validate_text_options(opts),
         {:ok, chunks} <- chunks(text, opts),
         {:ok, usage} <- usage_options(text, opts) do
      {:ok, build_text_script(text, chunks, usage)}
    else
      false -> {:error, :invalid_lab_stream_text}
      {:error, _reason} = error -> error
    end
  end

  def text(_text, _opts), do: {:error, :invalid_lab_stream_text_options}

  @doc "Builds a finite text response or raises with its stable validation reason."
  @spec text!(String.t(), keyword()) :: t()
  def text!(text, opts \\ []) do
    case text(text, opts) do
      {:ok, script} -> script
      {:error, reason} -> raise ArgumentError, "invalid Lab text stream: #{inspect(reason)}"
    end
  end

  @doc "Returns deterministic messages for Spectre's adapter conformance runner."
  @spec conformance_messages(t(), term()) :: {:ok, [term()]} | {:error, term()}
  def conformance_messages(%__MODULE__{} = script, token) do
    script.items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn
      {:stall, _index}, _acc ->
        {:halt, {:error, :lab_stream_stall_has_no_conformance_message}}

      {item, index}, {:ok, messages} ->
        message = {:spectre_lab_stream_item, token, index, item}
        {:cont, {:ok, [message | messages]}}
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_item(%ProviderEvent{} = event), do: normalize_events([event])
  defp normalize_item(events) when is_list(events), do: normalize_events(events)
  defp normalize_item({:events, events}) when is_list(events), do: normalize_events(events)
  defp normalize_item(:stall), do: {:ok, :stall}

  defp normalize_item({:transport_error, reason}) when not is_nil(reason),
    do: {:ok, {:transport_error, reason}}

  defp normalize_item(_item), do: {:error, :invalid_item}

  defp normalize_events([]), do: {:error, :empty_event_batch}

  defp normalize_events(events) do
    case Enum.find_value(events, &invalid_event/1) do
      nil -> {:ok, {:events, events}}
      reason -> {:error, reason}
    end
  end

  defp invalid_event(%ProviderEvent{} = event) do
    case ProviderEvent.validate(event) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp invalid_event(_event), do: :invalid_provider_event

  defp validate_text_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_lab_stream_text_options}

      Keyword.keys(opts) != Enum.uniq(Keyword.keys(opts)) ->
        {:error, :duplicate_lab_stream_text_options}

      Enum.any?(Keyword.keys(opts), &(&1 not in @text_options)) ->
        {:error, :unknown_lab_stream_text_options}

      true ->
        :ok
    end
  end

  defp chunks(text, opts) do
    case Keyword.fetch(opts, :chunks) do
      {:ok, chunks} -> explicit_chunks(text, chunks)
      :error -> sized_chunks(text, Keyword.get(opts, :chunk_size, 16))
    end
  end

  defp explicit_chunks(text, chunks) when is_list(chunks) do
    if chunks != [] and Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) > 0)) and
         IO.iodata_to_binary(chunks) == text do
      {:ok, chunks}
    else
      {:error, :invalid_lab_stream_chunks}
    end
  end

  defp explicit_chunks(_text, _chunks), do: {:error, :invalid_lab_stream_chunks}

  defp sized_chunks(text, size) when is_integer(size) and size > 0,
    do: {:ok, split_binary(text, size, [])}

  defp sized_chunks(_text, _size), do: {:error, :invalid_lab_stream_chunk_size}

  defp split_binary(<<>>, _size, chunks), do: Enum.reverse(chunks)

  defp split_binary(binary, size, chunks) when byte_size(binary) <= size,
    do: Enum.reverse([binary | chunks])

  defp split_binary(binary, size, chunks) do
    <<chunk::binary-size(^size), rest::binary>> = binary
    split_binary(rest, size, [chunk | chunks])
  end

  defp usage_options(text, opts) do
    defaults = %{
      input_tokens: 0,
      output_tokens: estimated_tokens(text),
      cost: 0,
      duration_ms: 0,
      usage_quality: :estimated,
      provider_request_id: "spectre-lab-fixture"
    }

    usage = Map.merge(defaults, Map.new(Keyword.take(opts, Map.keys(defaults))))

    cond do
      not non_neg_integer?(usage.input_tokens) ->
        {:error, :invalid_lab_stream_input_tokens}

      not non_neg_integer?(usage.output_tokens) ->
        {:error, :invalid_lab_stream_output_tokens}

      not is_number(usage.cost) or usage.cost < 0 ->
        {:error, :invalid_lab_stream_cost}

      not non_neg_integer?(usage.duration_ms) ->
        {:error, :invalid_lab_stream_duration}

      usage.usage_quality not in [:provider, :estimated, :unavailable] ->
        {:error, :invalid_lab_stream_usage_quality}

      not is_binary(usage.provider_request_id) or usage.provider_request_id == "" ->
        {:error, :invalid_lab_stream_provider_request_id}

      true ->
        {:ok, usage}
    end
  end

  defp build_text_script(text, chunks, usage) do
    started =
      ProviderEvent.new(:started,
        provider_sequence: 0,
        provider_request_id: usage.provider_request_id
      )

    {deltas, _consumed} =
      Enum.map_reduce(Enum.with_index(chunks, 1), 0, fn {chunk, sequence}, consumed ->
        consumed = consumed + byte_size(chunk)

        event =
          ProviderEvent.delta(chunk,
            provider_sequence: sequence,
            usage: cumulative_usage(usage, consumed, byte_size(text)),
            usage_quality: usage.usage_quality
          )

        {event, consumed}
      end)

    terminal_sequence = length(deltas) + 1
    final_usage = cumulative_usage(usage, byte_size(text), byte_size(text))

    usage_event =
      ProviderEvent.new(:usage,
        provider_sequence: terminal_sequence,
        usage: final_usage,
        usage_quality: usage.usage_quality
      )

    completed =
      ProviderEvent.completed(text,
        provider_sequence: terminal_sequence + 1,
        provider_request_id: usage.provider_request_id,
        usage: final_usage,
        usage_quality: usage.usage_quality
      )

    items = text_items(started, deltas, usage_event, completed)
    %__MODULE__{items: items}
  end

  defp text_items(started, [], usage, completed),
    do: [{:events, [started, usage, completed]}]

  defp text_items(started, [first | rest], usage, completed) do
    batches = [{:events, [started, first]} | Enum.map(rest, &{:events, [&1]})]

    List.update_at(batches, -1, fn {:events, events} ->
      {:events, events ++ [usage, completed]}
    end)
  end

  defp cumulative_usage(usage, consumed, total_bytes) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: scaled_integer(usage.output_tokens, consumed, total_bytes),
      total_tokens:
        usage.input_tokens + scaled_integer(usage.output_tokens, consumed, total_bytes),
      cost: scaled_number(usage.cost, consumed, total_bytes),
      duration_ms: scaled_integer(usage.duration_ms, consumed, total_bytes),
      output_bytes: consumed
    }
  end

  defp scaled_integer(value, _consumed, 0), do: value
  defp scaled_integer(value, consumed, total), do: div(value * consumed + total - 1, total)

  defp scaled_number(value, _consumed, 0), do: value
  defp scaled_number(value, consumed, total), do: value * consumed / total

  defp estimated_tokens(<<>>), do: 0
  defp estimated_tokens(text), do: max(div(byte_size(text) + 3, 4), 1)
  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
end
