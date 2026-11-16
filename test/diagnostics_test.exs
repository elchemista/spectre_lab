defmodule Spectre.Lab.DiagnosticsTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  defmodule Stack do
    use Spectre.Stack
  end

  defmodule App do
    use Spectre.Server

    @impl true
    def handle_flow(:unmatched, _input, ctx), do: respond(ctx, "ready")
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
  end

  setup %{tmp_dir: dir} do
    store = start_supervised!({Spectre.Ledger.ServerStore, path: Path.join(dir, "agent.ledger")})

    server =
      start_supervised!(
        {Spectre.Server,
         agent: Agent,
         consumer: self(),
         identity: %{conversation: "diagnostic-fixture"},
         gam: [storage: {:disk, Path.join(dir, "gam")}],
         checkpoint: {Spectre.Ledger.ServerStore, store, :agent}}
      )

    %{server: server}
  end

  test "developer facade preserves the authorized consumer and core projection", %{server: server} do
    assert {:ok, expected} = Spectre.Server.inspect(server, limit: 1)
    assert {:ok, ^expected} = Spectre.Lab.inspect(server, :operational, limit: 1)

    assert {:ok, expected_trace} = Spectre.Server.trace(server, "not-retained", limit: 1)
    assert {:ok, ^expected_trace} = Spectre.Lab.trace(server, "not-retained", limit: 1)
  end

  test "calling from another process cannot impersonate the consumer", %{server: server} do
    task =
      Task.async(fn ->
        {
          Spectre.Lab.inspect(server, :operational),
          Spectre.Lab.trace(server, "not-retained")
        }
      end)

    assert {{:error, _}, {:error, _}} = Task.await(task)
    assert {:ok, _} = Spectre.Lab.inspect(server, :operational)
  end

  test "unsupported modes and authority-shaped options do not broaden access", %{server: server} do
    assert {:error, :invalid_lab_inspection_mode} = Spectre.Lab.inspect(server, :admin)
    assert {:error, _} = Spectre.Lab.inspect(server, :operational, scope: :domain)
    assert {:error, _} = Spectre.Lab.trace(server, "not-retained", consumer: self())
    assert {:error, _} = Spectre.Lab.inspect(server, :operational, limit: 101)
  end
end
