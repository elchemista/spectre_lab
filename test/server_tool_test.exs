defmodule Spectre.Lab.ServerToolTest do
  use ExUnit.Case, async: true
  alias Spectre.Lab.ServerTool

  test "inspection validates real canonical snapshots and exposes only bounded summary" do
    snapshot = %{
      version: 1,
      pending: %{consent: %{secret: "private"}},
      inbox: %{},
      outbox: %{},
      sequence: 3,
      definition_fingerprint: %{version: 1},
      assigns: %{secret: "private"}
    }

    {:ok, encoded} = Spectre.Server.Checkpoint.encode_value(snapshot)
    assert {:ok, args} = ServerTool.prepare(:inspect, [encoded], %{})

    assert {:ok, %{codec_valid: true, pending: 1, sequence: 3} = result} =
             ServerTool.invoke(:inspect, args, %{})

    refute Map.has_key?(result, :assigns)
    refute Map.has_key?(result, :definition_fingerprint)
    assert :ok = Spectre.GAM.Canonical.Value.validate(result)
  end

  test "arbitrary canonical values and corrupt bytes are not Server checkpoints" do
    {:ok, encoded} = Spectre.GAM.Canonical.Value.encode(%{})

    assert {:error, :not_a_server_checkpoint} =
             ServerTool.invoke(:inspect, %{snapshot: encoded}, %{})

    assert {:error, _} = ServerTool.invoke(:inspect, %{snapshot: "corrupt"}, %{})
  end

  test "summary fields cannot carry arbitrary saved payloads" do
    {:ok, encoded} =
      Spectre.Server.Checkpoint.encode_value(%{
        pending: %{},
        inbox: %{},
        outbox: %{},
        sequence: 1,
        version: %{secret: "must not be projected"}
      })

    assert {:error, :not_a_server_checkpoint} =
             ServerTool.invoke(:inspect, %{snapshot: encoded}, %{})
  end

  @tag :tmp_dir
  test "logical inspection reads only the trusted current checkpoint inside the worker", %{
    tmp_dir: dir
  } do
    store = start_supervised!({Spectre.Ledger.ServerStore, path: Path.join(dir, "lab.ledger")})

    snapshot = %{
      version: 1,
      pending: %{},
      inbox: %{},
      outbox: %{},
      sequence: 7,
      assigns: %{secret: "private snapshot payload"}
    }

    {:ok, encoded} = Spectre.Server.Checkpoint.encode_value(snapshot)
    {:ok, 1} = Spectre.Ledger.ServerStore.put_new(store, :current, encoded)

    context = %{
      checkpoint_ref: %{adapter: Spectre.Ledger.ServerStore, store: store, key: :current}
    }

    assert {:ok, %{scope: :current} = args} = ServerTool.prepare(:inspect, [:checkpoint], %{})
    refute inspect(args) =~ "private"
    assert {:ok, %{sequence: 7} = summary} = ServerTool.invoke(:inspect, args, context)
    refute inspect(summary) =~ "private"

    assert {:error, :invalid_lab_request} =
             ServerTool.prepare(:inspect, [{:checkpoint, :other}], %{})

    assert {:error, :server_checkpoint_required} = ServerTool.invoke(:inspect, args, %{})
  end
end
