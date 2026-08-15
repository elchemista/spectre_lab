defmodule Spectre.Lab.TestCase do
  @moduledoc """
  ExUnit case template for isolated Spectre tests.

  Every test receives a caller-supervised `:sandbox` and a closed `:io_fuse`.
  Processes started with `start_lab_child/2` are shut down with the test.
  `start_fault_controller/2` starts a deterministic checkpoint/receipt fault
  script in that same sandbox.
  `assert_no_live_io/2` proves that a synchronous block authorized no live I/O;
  blocked attempts are permitted because their thunk never ran.
  """

  use ExUnit.CaseTemplate

  alias Spectre.Lab.IOFuse
  alias Spectre.Lab.Fault.Controller
  alias Spectre.Lab.Sandbox

  using do
    quote do
      import Spectre.Lab.TestCase,
        only: [
          assert_no_live_io: 2,
          start_fault_controller: 1,
          start_fault_controller: 2,
          start_lab_child: 2
        ]
    end
  end

  setup _context do
    {:ok, sandbox} = ExUnit.Callbacks.start_supervised({Sandbox, []})
    {:ok, io_fuse} = Sandbox.start_child(sandbox, {IOFuse, []})

    {:ok, sandbox: sandbox, io_fuse: io_fuse}
  end

  @doc "Starts a process inside the sandbox from a Lab case context."
  @spec start_lab_child(%{required(:sandbox) => pid()}, Sandbox.child_spec()) ::
          DynamicSupervisor.on_start_child()
  def start_lab_child(%{sandbox: sandbox}, child_spec) when is_pid(sandbox) do
    Sandbox.start_child(sandbox, child_spec)
  end

  def start_lab_child(_context, _child_spec), do: {:error, :invalid_lab_test_context}

  @doc "Starts a validated persistence-fault script inside the case sandbox."
  @spec start_fault_controller(map(), Controller.script()) :: GenServer.on_start()
  def start_fault_controller(context, script \\ %{}) do
    start_lab_child(context, {Controller, script: script})
  end

  @doc """
  Runs `thunk` and asserts that no live I/O dispatch was authorized.

  The assertion covers synchronous work completed before `thunk` returns.
  """
  @spec assert_no_live_io(pid(), (-> result)) :: result when result: term()
  def assert_no_live_io(io_fuse, thunk)
      when is_pid(io_fuse) and is_function(thunk, 0) do
    before = IOFuse.snapshot(io_fuse)
    result = thunk.()
    after_run = IOFuse.snapshot(io_fuse)

    ExUnit.Assertions.assert(
      authorized_completions(before) == authorized_completions(after_run),
      "expected no live I/O dispatch, but the fuse authorized work"
    )

    result
  end

  def assert_no_live_io(_io_fuse, _thunk) do
    ExUnit.Assertions.flunk("expected a Lab I/O fuse and a zero-arity function")
  end

  @spec authorized_completions(IOFuse.snapshot()) :: map()
  defp authorized_completions(%{counters: counters}) do
    Map.take(counters, [:allowed, :succeeded, :failed])
  end
end
