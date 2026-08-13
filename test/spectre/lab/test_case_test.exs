defmodule SpectreLabTestCaseTest do
  use Spectre.Lab.TestCase, async: true

  alias Spectre.Lab.IOFuse
  alias Spectre.Lab.Sandbox

  test "provides an isolated sandbox and a closed I/O fuse", context do
    assert is_pid(context.sandbox)
    assert is_pid(context.io_fuse)
    assert %{state: :closed} = IOFuse.snapshot(context.io_fuse)

    assert Enum.any?(Sandbox.children(context.sandbox), fn
             {:undefined, pid, :worker, [IOFuse]} -> pid == context.io_fuse
             _child -> false
           end)
  end

  test "starts caller resources under the per-test sandbox", context do
    assert {:ok, child} = start_lab_child(context, {Agent, fn -> 41 end})
    assert Agent.get(child, &(&1 + 1)) == 42
  end

  test "asserts zero authorized dispatch while allowing blocked attempts", %{io_fuse: fuse} do
    assert {:error, :live_io_blocked} =
             assert_no_live_io(fuse, fn ->
               IOFuse.dispatch(fuse, fn -> send(self(), :must_not_run) end)
             end)

    refute_received :must_not_run
    assert %{counters: %{allowed: 0, blocked: 1}} = IOFuse.snapshot(fuse)
  end

  test "fails when the block authorizes live work", %{io_fuse: fuse} do
    :ok = IOFuse.open(fuse)

    assert_raise ExUnit.AssertionError, ~r/fuse authorized work/, fn ->
      assert_no_live_io(fuse, fn -> IOFuse.dispatch(fuse, fn -> :live end) end)
    end
  end
end
