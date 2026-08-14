defmodule SpectreLabIOFuseTest do
  use ExUnit.Case, async: true

  alias Spectre.Lab.IOFuse

  test "starts unnamed and closed, and never evaluates a blocked thunk" do
    fuse = start_supervised!(IOFuse)
    assert {:registered_name, []} = Process.info(fuse, :registered_name)

    assert {:error, :live_io_blocked} =
             IOFuse.dispatch(fuse, fn -> send(self(), :live_side_effect) end)

    refute_received :live_side_effect

    assert IOFuse.snapshot(fuse) == %{
             state: :closed,
             counters: %{attempted: 1, allowed: 0, blocked: 1, succeeded: 0, failed: 0}
           }
  end

  test "runs only explicitly authorized work and records redacted outcomes" do
    fuse = start_supervised!(IOFuse)

    assert :ok = IOFuse.open(fuse)

    assert {:ok, {:sensitive, "return value"}} =
             IOFuse.dispatch(fuse, fn -> {:sensitive, "return value"} end)

    assert {:error, {:live_io_exception, RuntimeError}} =
             IOFuse.dispatch(fuse, fn -> raise "secret failure payload" end)

    assert :ok = IOFuse.close(fuse)
    snapshot = IOFuse.snapshot(fuse)

    assert snapshot == %{
             state: :closed,
             counters: %{attempted: 2, allowed: 2, blocked: 0, succeeded: 1, failed: 1}
           }

    refute inspect(snapshot) =~ "sensitive"
    refute inspect(snapshot) =~ "secret"
  end

  test "reduces exits and throws to their failure class" do
    fuse = start_supervised!(IOFuse)
    :ok = IOFuse.open(fuse)

    assert {:error, {:live_io_failure, :throw}} = IOFuse.dispatch(fuse, fn -> throw(:secret) end)
    assert {:error, {:live_io_failure, :exit}} = IOFuse.dispatch(fuse, fn -> exit(:secret) end)

    assert %{counters: %{failed: 2}} = IOFuse.snapshot(fuse)
  end

  test "keeps the startup surface fail-closed" do
    assert {:error, :invalid_lab_io_fuse_options} = IOFuse.start_link(open: true)
    assert {:error, :invalid_live_io_dispatch} = IOFuse.dispatch(self(), :not_a_function)
  end
end
