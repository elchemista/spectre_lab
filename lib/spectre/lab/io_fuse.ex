defmodule Spectre.Lab.IOFuse do
  @moduledoc """
  Caller-owned fail-closed gate for live I/O in tests.

  The fuse starts closed and never registers a process name. `dispatch/2`
  refuses to evaluate its function until the caller explicitly invokes
  `open/1`. Its snapshot contains counters only: arguments, return values and
  failure reasons are never retained by the process.

  Authorization is decided atomically by the fuse. A dispatch authorized while
  open remains authorized if another process closes the fuse before the
  function returns.
  """

  use GenServer

  @type counters :: %{
          required(:attempted) => non_neg_integer(),
          required(:allowed) => non_neg_integer(),
          required(:blocked) => non_neg_integer(),
          required(:succeeded) => non_neg_integer(),
          required(:failed) => non_neg_integer()
        }

  @type snapshot :: %{required(:state) => :closed | :open, required(:counters) => counters()}

  @doc "Starts a closed, unregistered fuse linked to the caller."
  @spec start_link([]) :: GenServer.on_start()
  def start_link(opts \\ [])

  def start_link([]), do: GenServer.start_link(__MODULE__, :closed)
  def start_link(_opts), do: {:error, :invalid_lab_io_fuse_options}

  @doc "Explicitly opens the fuse for subsequent dispatches."
  @spec open(pid()) :: :ok
  def open(fuse) when is_pid(fuse), do: GenServer.call(fuse, :open)

  @doc "Closes the fuse for subsequent dispatches."
  @spec close(pid()) :: :ok
  def close(fuse) when is_pid(fuse), do: GenServer.call(fuse, :close)

  @doc "Returns only the fuse state and redacted aggregate counters."
  @spec snapshot(pid()) :: snapshot()
  def snapshot(fuse) when is_pid(fuse), do: GenServer.call(fuse, :snapshot)

  @doc """
  Runs a zero-arity function only when the fuse is open.

  Exceptions and non-local returns are reduced to their class so that an I/O
  error cannot leak its payload through the test harness.
  """
  @spec dispatch(pid(), (-> result)) ::
          {:ok, result}
          | {:error, :live_io_blocked}
          | {:error, {:live_io_exception, module()}}
          | {:error, {:live_io_failure, :exit | :throw}}
        when result: term()
  def dispatch(fuse, thunk) when is_pid(fuse) and is_function(thunk, 0) do
    case GenServer.call(fuse, :authorize) do
      :blocked ->
        {:error, :live_io_blocked}

      :allowed ->
        fuse
        |> invoke(thunk)
        |> record_result(fuse)
    end
  end

  def dispatch(_fuse, _thunk), do: {:error, :invalid_live_io_dispatch}

  @impl true
  def init(:closed), do: {:ok, %{state: :closed, counters: empty_counters()}}

  @impl true
  def handle_call(:open, _from, state), do: {:reply, :ok, %{state | state: :open}}

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | state: :closed}}

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:authorize, _from, %{state: :closed} = state) do
    counters = increment_many(state.counters, [:attempted, :blocked])
    {:reply, :blocked, %{state | counters: counters}}
  end

  def handle_call(:authorize, _from, %{state: :open} = state) do
    counters = increment_many(state.counters, [:attempted, :allowed])
    {:reply, :allowed, %{state | counters: counters}}
  end

  def handle_call({:record, outcome}, _from, state) when outcome in [:succeeded, :failed] do
    {:reply, :ok, %{state | counters: Map.update!(state.counters, outcome, &(&1 + 1))}}
  end

  @spec invoke(pid(), (-> term())) :: {:succeeded, term()} | {:failed, term()}
  defp invoke(_fuse, thunk) do
    {:succeeded, thunk.()}
  rescue
    exception -> {:failed, {:error, {:live_io_exception, exception.__struct__}}}
  catch
    kind, _reason when kind in [:exit, :throw] ->
      {:failed, {:error, {:live_io_failure, kind}}}
  end

  @spec record_result({:succeeded, term()} | {:failed, term()}, pid()) :: term()
  defp record_result({:succeeded, value}, fuse) do
    :ok = GenServer.call(fuse, {:record, :succeeded})
    {:ok, value}
  end

  defp record_result({:failed, error}, fuse) do
    :ok = GenServer.call(fuse, {:record, :failed})
    error
  end

  @spec empty_counters() :: counters()
  defp empty_counters do
    %{attempted: 0, allowed: 0, blocked: 0, succeeded: 0, failed: 0}
  end

  @spec increment_many(counters(), [atom()]) :: counters()
  defp increment_many(counters, keys) do
    Enum.reduce(keys, counters, &Map.update!(&2, &1, fn count -> count + 1 end))
  end
end
