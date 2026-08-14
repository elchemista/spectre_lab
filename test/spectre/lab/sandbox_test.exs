defmodule SpectreLabSandboxTest do
  use ExUnit.Case, async: true

  alias Spectre.Lab.Sandbox

  test "owns unnamed children and shuts them down with the supervision boundary" do
    {:ok, sandbox} = Sandbox.start_link(max_children: 2)
    assert {:registered_name, []} = Process.info(sandbox, :registered_name)

    assert {:ok, child} = Sandbox.start_child(sandbox, {Agent, fn -> :ready end})
    assert Agent.get(child, & &1) == :ready
    assert [{:undefined, ^child, :worker, [Agent]}] = Sandbox.children(sandbox)

    monitor = Process.monitor(child)
    assert :ok = Supervisor.stop(sandbox)
    assert_receive {:DOWN, ^monitor, :process, ^child, :shutdown}
  end

  test "terminates an individual child without affecting the sandbox" do
    start_supervised!({Sandbox, []})
    |> then(fn sandbox ->
      assert {:ok, child} = Sandbox.start_child(sandbox, {Agent, fn -> %{} end})
      assert :ok = Sandbox.terminate_child(sandbox, child)
      refute Process.alive?(child)
      assert Process.alive?(sandbox)
      assert [] = Sandbox.children(sandbox)
    end)
  end

  test "rejects registration and malformed limits instead of forwarding open options" do
    assert {:error, :invalid_lab_sandbox_options} = Sandbox.start_link(:invalid)
    assert {:error, :invalid_lab_sandbox_options} = Sandbox.start_link(name: __MODULE__)

    assert {:error, :invalid_lab_sandbox_max_children} =
             Sandbox.start_link(max_children: -1)

    assert {:error, :invalid_lab_sandbox_options} =
             Sandbox.start_link(max_children: 1, max_children: 2)

    assert {:error, :invalid_lab_sandbox} = Sandbox.start_child(:not_a_pid, Agent)
    assert {:error, :not_found} = Sandbox.terminate_child(:not_a_pid, :not_a_pid)
  end
end
