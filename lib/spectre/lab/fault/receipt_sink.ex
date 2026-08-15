defmodule Spectre.Lab.Fault.ReceiptSink do
  @moduledoc """
  Scripted fault adapter around a public `Spectre.Receipt.Sink`.

  Configure it with a caller-owned `Spectre.Lab.Fault.Controller` and an
  ordinary receipt sink:

      {Spectre.Lab.Fault.ReceiptSink,
       controller: controller,
       delegate: {MyReceiptSink, namespace: "test"}}

  The adapter supports deterministic failures before all four sink callbacks.
  `:receipt_append` and `:receipt_put_payload` additionally support
  `{:commit_then_return, {:error, {:ambiguous, reason}}}` to model a committed
  write whose acknowledgement was lost. Delegation always crosses Spectre's
  public sink boundary, so validation, idempotency, and reconciliation retain
  the same semantics as production.
  """

  @behaviour Spectre.Receipt.Sink

  alias Spectre.Lab.Fault.Controller
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink, as: CoreSink

  @reserved_options [:controller, :delegate]

  @impl Spectre.Receipt.Sink
  def append(%Envelope{} = envelope, opts) do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :receipt_append) do
      execute_mutation(action, fn ->
        CoreSink.append(config.delegate, envelope, config.forwarded)
      end)
    end
  end

  @impl Spectre.Receipt.Sink
  def lookup(id, opts) when is_binary(id) and id != "" do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :receipt_lookup) do
      execute_read(action, fn -> CoreSink.lookup(config.delegate, id, config.forwarded) end)
    end
  end

  def lookup(_id, _opts), do: {:error, :invalid_fault_receipt_id}

  @impl Spectre.Receipt.Sink
  def put_payload(%Envelope{} = envelope, opts) do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :receipt_put_payload) do
      execute_mutation(action, fn ->
        CoreSink.put_payload(config.delegate, envelope, config.forwarded)
      end)
    end
  end

  @impl Spectre.Receipt.Sink
  def get_payload(ref, opts) when is_binary(ref) and ref != "" do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :receipt_get_payload) do
      execute_read(action, fn -> CoreSink.get_payload(config.delegate, ref, config.forwarded) end)
    end
  end

  def get_payload(_ref, _opts), do: {:error, :invalid_fault_receipt_payload_ref}

  @spec execute_read(Controller.action() | {:error, term()}, (-> term())) :: term()
  defp execute_read(:pass, delegate), do: delegate.()
  defp execute_read({:fail_before, reason}, _delegate), do: {:error, reason}

  defp execute_read({:error, reason}, _delegate),
    do: {:error, {:receipt_fault_controller, reason}}

  @spec execute_mutation(Controller.action() | {:error, term()}, (-> term())) :: term()
  defp execute_mutation(:pass, delegate), do: delegate.()
  defp execute_mutation({:fail_before, reason}, _delegate), do: {:error, reason}

  defp execute_mutation({:commit_then_return, reply}, delegate) do
    case delegate.() do
      {:ok, _value} -> reply
      {:error, _reason} = error -> error
    end
  end

  defp execute_mutation({:error, reason}, _delegate),
    do: {:error, {:receipt_fault_controller, reason}}

  @spec normalize_config(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_config(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, controller} <- fetch_once(opts, :controller),
         true <- is_pid(controller) and Process.alive?(controller),
         {:ok, delegate_config} <- fetch_once(opts, :delegate),
         {:ok, {module, delegate_opts} = delegate} <- CoreSink.normalize(delegate_config),
         true <- module != __MODULE__ and Keyword.keyword?(delegate_opts) do
      {:ok,
       %{
         controller: controller,
         delegate: delegate,
         forwarded: Keyword.drop(opts, @reserved_options)
       }}
    else
      false -> invalid_config(:invalid_option)
      {:ok, nil} -> invalid_config(:receipt_sink_disabled)
      {:error, {:invalid_receipt_sink, _reason}} -> invalid_config(:invalid_delegate)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_config(_opts), do: invalid_config(:options_required)

  @spec fetch_once(keyword(), atom()) :: {:ok, term()} | {:error, term()}
  defp fetch_once(opts, key) do
    case Keyword.get_values(opts, key) do
      [value] -> {:ok, value}
      [] -> invalid_config({:missing_option, key})
      _values -> invalid_config({:duplicate_option, key})
    end
  end

  @spec invalid_config(term()) :: {:error, term()}
  defp invalid_config(reason), do: {:error, {:invalid_fault_receipt_sink, reason}}
end
