defmodule Spectre.Lab.Fault.CheckpointStore do
  @moduledoc """
  Scripted fault adapter around a public Spectre checkpoint store.

  Configure it with a caller-owned `Spectre.Lab.Fault.Controller` and any
  ordinary `Spectre.Instance.CheckpointStore` configuration:

      {Spectre.Lab.Fault.CheckpointStore,
       controller: controller,
       delegate: {MyStore, namespace: "test"}}

  Adapter-only keys are removed before call options reach the delegate. All
  delegation goes through the public checkpoint-store boundary, preserving its
  reply normalization and ambiguity semantics.
  """

  @behaviour Spectre.Instance.CheckpointStore

  alias Spectre.Instance.CheckpointStore
  alias Spectre.Lab.Fault.Controller

  @reserved_options [:controller, :delegate]

  @impl true
  def load(ref, opts) do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :load) do
      execute_load(action, config, ref)
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :compare_and_swap) do
      execute_mutation(action, fn ->
        CheckpointStore.persist(
          config.delegate,
          ref,
          checkpoint,
          expected,
          revision,
          config.forwarded
        )
      end)
    end
  end

  @impl true
  def migrate_instance_key(legacy_ref, stable_ref, legacy, migrated, opts) do
    with {:ok, config} <- normalize_config(opts),
         action <- Controller.next(config.controller, :migrate_instance_key) do
      execute_mutation(action, fn ->
        CheckpointStore.migrate_instance_key(
          config.delegate,
          legacy_ref,
          stable_ref,
          legacy,
          migrated,
          config.forwarded
        )
      end)
    end
  end

  @spec execute_load(Controller.action() | {:error, term()}, map(), term()) ::
          :not_found | {:ok, String.t() | map()} | {:error, term()}
  defp execute_load(:pass, config, ref) do
    CheckpointStore.load(config.delegate, ref, config.forwarded)
  end

  defp execute_load({:fail_before, reason}, _config, _ref), do: {:error, reason}

  defp execute_load({:error, reason}, _config, _ref),
    do: {:error, {:checkpoint_fault_controller, reason}}

  @spec execute_mutation(Controller.action() | {:error, term()}, (-> term())) ::
          :ok | {:error, term()}
  defp execute_mutation(:pass, delegate), do: delegate.()
  defp execute_mutation({:fail_before, reason}, _delegate), do: {:error, reason}

  defp execute_mutation({:commit_then_return, reply}, delegate) do
    case delegate.() do
      :ok -> reply
      {:error, _reason} = error -> error
    end
  end

  defp execute_mutation({:error, reason}, _delegate),
    do: {:error, {:checkpoint_fault_controller, reason}}

  @spec normalize_config(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_config(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, controller} <- fetch_once(opts, :controller),
         true <- is_pid(controller) and Process.alive?(controller),
         {:ok, delegate_config} <- fetch_once(opts, :delegate),
         {:ok, {module, delegate_opts} = delegate} <- CheckpointStore.normalize(delegate_config),
         true <- module != __MODULE__ and Keyword.keyword?(delegate_opts) do
      {:ok,
       %{
         controller: controller,
         delegate: delegate,
         forwarded: Keyword.drop(opts, @reserved_options)
       }}
    else
      false -> invalid_config(:invalid_option)
      {:ok, nil} -> invalid_config(:checkpointing_disabled)
      {:error, {:invalid_checkpoint_store, _value}} -> invalid_config(:invalid_delegate)
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
  defp invalid_config(reason), do: {:error, {:invalid_fault_checkpoint_store, reason}}
end
