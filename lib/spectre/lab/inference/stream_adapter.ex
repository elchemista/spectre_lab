defmodule Spectre.Lab.Inference.StreamAdapter do
  @moduledoc """
  Pull-driven, network-free streaming adapter for Spectre integration tests.

  The adapter consumes a `Spectre.Lab.Inference.StreamScript`. Each demand
  schedules at most one owned mailbox message in the real stream-session
  process, so tests exercise Spectre's Enumerable, credit, fencing, sanitizer,
  budget, cancellation, and terminal paths without calling a provider.

      script = Spectre.Lab.Inference.StreamScript.text!("hello", chunk_size: 2)

      Spectre.stream(instance, "stream",
        model: MyTestModel,
        plan_actions?: false,
        stream_adapter: __MODULE__,
        stream_adapter_opts: [script: script, observer: self()]
      )

  Observer messages contain lifecycle facts only; response text and failure
  payloads are never copied into them. The adapter implements bounded-fixture
  and resume callbacks required by the Spectre 0.3.3 public contract.
  """

  @behaviour Spectre.Inference.StreamAdapter

  alias Spectre.Inference.ProviderEvent
  alias Spectre.Lab.Inference.StreamScript

  @bound_keys [:max_transport_chunk_bytes, :max_parser_residual_bytes]

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, opts) do
    capabilities = [:stream, :pull_transport, :incremental_usage, :resume]

    capabilities =
      if Keyword.get(opts, :cost_usage, false),
        do: [:cost_usage | capabilities],
        else: capabilities

    capabilities =
      if Keyword.has_key?(opts, :reconcile_result),
        do: [:reconcile | capabilities],
        else: capabilities

    MapSet.new(capabilities)
  end

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts) do
    case Keyword.fetch(opts, :open_error) do
      {:ok, reason} -> {:error, reason}
      :error -> build_state(opts, 0)
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def resume(_descriptor, {:spectre_lab, consumed}, opts)
      when is_integer(consumed) and consumed >= 0 do
    build_state(opts, consumed)
  end

  def resume(_descriptor, _cursor, _opts), do: {:error, :invalid_lab_stream_cursor}

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{outstanding: nil, items: [item | rest]} = state) do
    index = state.position + 1
    notify(state, {:demand, self(), index})

    next = %{state | items: rest, outstanding: {index, item}, position: index}

    case {state.delivery, item} do
      {_delivery, :stall} ->
        {:ok, next}

      {:mailbox, item} ->
        send(self(), {:spectre_lab_stream_item, state.token, index, item})
        {:ok, next}

      {:external, _item} ->
        {:ok, next}
    end
  end

  def request_transport_item(%{outstanding: nil, items: []}),
    do: {:error, :lab_stream_script_exhausted}

  def request_transport_item(_state), do: {:error, :lab_stream_demand_already_outstanding}

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(
        {:spectre_lab_stream_bound, token, kind, payload},
        %{token: token, bounds: bounds} = state
      )
      when kind in [:transport_chunk, :parser_residual] and is_binary(payload) do
    limit = Map.fetch!(bounds, bound_key(kind))

    if byte_size(payload) > limit,
      do: {:error, :provider_stream_overflow, state},
      else: {:ok, [], state}
  end

  def handle_transport(
        {:spectre_lab_stream_item, token, index, item},
        %{token: token, outstanding: {index, item}} = state
      ) do
    deliver_item(item, index, %{state | outstanding: nil})
  end

  def handle_transport({:spectre_lab_stream_item, token, _index, _item}, %{token: token} = state),
    do: {:error, :lab_stream_fixture_mismatch, state}

  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(state, reason) do
    notify(state, {:cancelled, self(), reason_class(reason)})
    state.cancel_reply
  end

  @impl Spectre.Inference.StreamAdapter
  def reconcile(_descriptor, _provider_request_id, opts) do
    case Keyword.get(opts, :reconcile_result, :not_found) do
      {:ok, _result} = result -> result
      :pending -> :pending
      :not_found -> :not_found
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_lab_stream_reconcile_result}
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def conformance_fixture(kind, oversized, _descriptor, opts)
      when kind in [:transport_chunk, :parser_residual] and is_binary(oversized) do
    with {:ok, bounds} <- bounds(opts) do
      token = make_ref()

      state = %{
        bounds: bounds,
        cancel_reply: :ok,
        delivery: :external,
        items: [],
        observer: nil,
        outstanding: nil,
        position: 0,
        token: token
      }

      {:ok, {:spectre_lab_stream_bound, token, kind, oversized}, state}
    end
  end

  defp build_state(opts, consumed) do
    with {:ok, script} <- fetch_script(opts),
         true <- consumed <= length(script.items),
         {:ok, bounds} <- bounds(opts),
         {:ok, observer} <- observer(opts),
         {:ok, delivery} <- delivery(opts),
         {:ok, cancel_reply} <- cancel_reply(opts),
         {:ok, metadata} <- metadata(opts) do
      token = Keyword.get(opts, :stream_token, make_ref())

      state = %{
        bounds: bounds,
        cancel_reply: cancel_reply,
        delivery: delivery,
        items: Enum.drop(script.items, consumed),
        observer: observer,
        outstanding: nil,
        position: consumed,
        token: token
      }

      notify(state, {:opened, self(), consumed})
      {:ok, state, Map.merge(%{fixture: true, transport: :spectre_lab_pull}, metadata)}
    else
      false -> {:error, :invalid_lab_stream_cursor}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_script(opts) do
    case Keyword.get_values(opts, :script) do
      [script] -> StreamScript.new(script)
      [] -> {:error, :missing_lab_stream_script}
      _scripts -> {:error, :duplicate_lab_stream_script}
    end
  end

  defp bounds(opts) do
    with bounds when is_list(bounds) <- Keyword.get(opts, :spectre_bounds),
         true <- Keyword.keyword?(bounds),
         true <- Keyword.keys(bounds) == Enum.uniq(Keyword.keys(bounds)),
         true <- Enum.sort(Keyword.keys(bounds)) == Enum.sort(@bound_keys),
         true <- Enum.all?(@bound_keys, &positive_bound?(bounds, &1)) do
      {:ok, Map.new(bounds)}
    else
      _invalid -> {:error, :invalid_lab_stream_bounds}
    end
  end

  defp positive_bound?(bounds, key) do
    value = Keyword.get(bounds, key)
    is_integer(value) and value > 0
  end

  defp observer(opts) do
    case Keyword.get(opts, :observer) do
      nil -> {:ok, nil}
      observer when is_pid(observer) -> {:ok, observer}
      _invalid -> {:error, :invalid_lab_stream_observer}
    end
  end

  defp delivery(opts) do
    case Keyword.get(opts, :delivery, :mailbox) do
      delivery when delivery in [:mailbox, :external] -> {:ok, delivery}
      _invalid -> {:error, :invalid_lab_stream_delivery}
    end
  end

  defp cancel_reply(opts) do
    case Keyword.get(opts, :cancel_reply, :ok) do
      :ok -> {:ok, :ok}
      {:error, _reason} = error -> {:ok, error}
      _invalid -> {:error, :invalid_lab_stream_cancel_reply}
    end
  end

  defp metadata(opts) do
    case Keyword.get(opts, :metadata, %{}) do
      metadata when is_map(metadata) and not is_struct(metadata) -> {:ok, metadata}
      _invalid -> {:error, :invalid_lab_stream_metadata}
    end
  end

  defp deliver_item({:events, events}, index, state) do
    events = Enum.map(events, &put_cursor(&1, index))
    {:ok, events, state}
  end

  defp deliver_item({:transport_error, reason}, _index, state), do: {:error, reason, state}
  defp deliver_item(:stall, _index, state), do: {:error, :lab_stream_stall_delivered, state}

  defp put_cursor(%ProviderEvent{cursor: nil} = event, index),
    do: %{event | cursor: {:spectre_lab, index}}

  defp put_cursor(%ProviderEvent{} = event, _index), do: event

  defp notify(%{observer: nil}, _event), do: :ok

  defp notify(%{observer: observer}, event) do
    send(observer, {:spectre_lab_stream, event})
    :ok
  end

  defp bound_key(:transport_chunk), do: :max_transport_chunk_bytes
  defp bound_key(:parser_residual), do: :max_parser_residual_bytes

  defp reason_class(reason) when is_atom(reason) and not is_nil(reason), do: reason
  defp reason_class({reason, _detail}) when is_atom(reason) and not is_nil(reason), do: reason

  defp reason_class({reason, _first, _second}) when is_atom(reason) and not is_nil(reason),
    do: reason

  defp reason_class(_reason), do: :error
end
