defmodule Spectre.Lab.Fault.Controller do
  @moduledoc """
  Caller-owned deterministic script for persistence fault injection.

  Scripts are maps whose keys are supported checkpoint-store or receipt-sink
  operations and whose values are FIFO action lists. An exhausted or omitted
  operation passes by default. The controller is deliberately unregistered
  and serializes script consumption without timers or global state.

      %{
        compare_and_swap: [
          :pass,
          {:fail_before, :unavailable},
          {:commit_then_return, {:error, {:ambiguous, :lost_ack}}}
        ],
        receipt_put_payload: [
          {:commit_then_return, {:error, {:ambiguous, :staging_ack_lost}}}
        ]
      }

  `:commit_then_return` is accepted only for mutation operations and only with
  Spectre's ambiguity shape. It first lets the wrapped adapter commit and then
  returns the scripted lost-ack result.
  """

  use GenServer

  @checkpoint_operations [:load, :compare_and_swap, :migrate_instance_key]
  @receipt_operations [
    :receipt_append,
    :receipt_lookup,
    :receipt_put_payload,
    :receipt_get_payload
  ]
  @operations @checkpoint_operations ++ @receipt_operations
  @mutation_operations [
    :compare_and_swap,
    :migrate_instance_key,
    :receipt_append,
    :receipt_put_payload
  ]
  @action_names [:pass, :fail_before, :commit_then_return]

  @type operation ::
          :load
          | :compare_and_swap
          | :migrate_instance_key
          | :receipt_append
          | :receipt_lookup
          | :receipt_put_payload
          | :receipt_get_payload
  @type action ::
          :pass
          | {:fail_before, term()}
          | {:commit_then_return, {:error, {:ambiguous, term()}}}
  @type script :: %{optional(operation()) => [action()]}

  @type snapshot :: %{
          required(:calls) => %{required(operation()) => non_neg_integer()},
          required(:actions) => %{
            required(:pass) => non_neg_integer(),
            required(:fail_before) => non_neg_integer(),
            required(:commit_then_return) => non_neg_integer()
          },
          required(:remaining) => %{required(operation()) => non_neg_integer()}
        }

  @doc "Starts an unregistered controller with an optional validated script."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, script} <- normalize_options(opts) do
      GenServer.start_link(__MODULE__, script)
    end
  end

  @doc "Consumes and returns the next action for one supported persistence operation."
  @spec next(pid(), operation()) :: action() | {:error, term()}
  def next(controller, operation)
      when is_pid(controller) and operation in @operations do
    GenServer.call(controller, {:next, operation})
  end

  def next(_controller, _operation), do: {:error, :invalid_checkpoint_fault_request}

  @doc "Returns counters and remaining action counts without script payloads."
  @spec snapshot(pid()) :: snapshot()
  def snapshot(controller) when is_pid(controller), do: GenServer.call(controller, :snapshot)

  @impl true
  def init(script) do
    {:ok,
     %{
       queues: complete_queues(script),
       calls: zero_map(@operations),
       actions: zero_map(@action_names)
     }}
  end

  @impl true
  def handle_call({:next, operation}, _from, state) do
    {action, queues} = take_action(state.queues, operation)

    next = %{
      state
      | queues: queues,
        calls: Map.update!(state.calls, operation, &(&1 + 1)),
        actions: Map.update!(state.actions, action_name(action), &(&1 + 1))
    }

    {:reply, action, next}
  end

  def handle_call(:snapshot, _from, state) do
    remaining = Map.new(state.queues, fn {operation, actions} -> {operation, length(actions)} end)
    {:reply, %{calls: state.calls, actions: state.actions, remaining: remaining}, state}
  end

  @spec normalize_options(term()) :: {:ok, script()} | {:error, term()}
  defp normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) in [[], [:script]],
         script <- Keyword.get(opts, :script, %{}),
         :ok <- validate_script(script) do
      {:ok, script}
    else
      false -> {:error, :invalid_checkpoint_fault_options}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_options(_opts), do: {:error, :invalid_checkpoint_fault_options}

  @spec validate_script(term()) :: :ok | {:error, term()}
  defp validate_script(script) when is_map(script) and not is_struct(script) do
    if Enum.all?(script, fn {operation, actions} ->
         operation in @operations and is_list(actions) and
           Enum.all?(actions, &valid_action?(operation, &1))
       end) do
      :ok
    else
      {:error, :invalid_checkpoint_fault_script}
    end
  end

  defp validate_script(_script), do: {:error, :invalid_checkpoint_fault_script}

  @spec valid_action?(operation(), term()) :: boolean()
  defp valid_action?(_operation, :pass), do: true
  defp valid_action?(_operation, {:fail_before, _reason}), do: true

  defp valid_action?(operation, {:commit_then_return, {:error, {:ambiguous, _reason}}}),
    do: operation in @mutation_operations

  defp valid_action?(_operation, _action), do: false

  @spec complete_queues(script()) :: %{required(operation()) => [action()]}
  defp complete_queues(script) do
    Map.new(@operations, &{&1, Map.get(script, &1, [])})
  end

  @spec zero_map([atom()]) :: map()
  defp zero_map(keys), do: Map.new(keys, &{&1, 0})

  @spec take_action(map(), operation()) :: {action(), map()}
  defp take_action(queues, operation) do
    case Map.fetch!(queues, operation) do
      [action | rest] -> {action, Map.put(queues, operation, rest)}
      [] -> {:pass, queues}
    end
  end

  @spec action_name(action()) :: :pass | :fail_before | :commit_then_return
  defp action_name(:pass), do: :pass
  defp action_name({:fail_before, _reason}), do: :fail_before
  defp action_name({:commit_then_return, _reply}), do: :commit_then_return
end
