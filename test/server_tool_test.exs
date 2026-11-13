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
end
