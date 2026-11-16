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

  test "explicit summary preserves the original request and unsupported modes fail closed" do
    assert ServerTool.prepare(:inspect, [:checkpoint], %{}) ==
             ServerTool.prepare(:inspect, [:checkpoint, :summary], %{})

    for args <- [
          [:checkpoint, :admin],
          [:checkpoint, :operational, [scope: :domain]],
          [:interaction, "id", [server: self()]],
          [:interaction, ""],
          [:interaction, String.duplicate("a", 257)],
          [:interaction, :not_a_binary]
        ] do
      assert {:error, :invalid_lab_request} = ServerTool.prepare(:inspect, args, %{})
    end
  end

  @tag :tmp_dir
  test "new projections use only the calling Skill checkpoint and never return saved payloads", %{
    tmp_dir: dir
  } do
    store = start_supervised!({Spectre.Ledger.ServerStore, path: Path.join(dir, "skills.ledger")})

    own_snapshot = %{
      version: 1,
      sequence: 9,
      pending: %{},
      inbox: %{},
      outbox: %{},
      assigns: %{secret: "OWN PRIVATE PAYLOAD"}
    }

    {:ok, encoded} = Spectre.Server.Checkpoint.encode_value(own_snapshot)
    {:ok, sibling} = Spectre.Server.Checkpoint.encode_value(%{own_snapshot | sequence: 999})
    {:ok, 1} = Spectre.Ledger.ServerStore.put_new(store, :own_skill, encoded)
    {:ok, 2} = Spectre.Ledger.ServerStore.put_new(store, :sibling, sibling)

    context = %{
      checkpoint_ref: %{adapter: Spectre.Ledger.ServerStore, store: store, key: :own_skill}
    }

    assert {:ok, operational} = Spectre.Server.Diagnostics.checkpoint(encoded)
    assert {:ok, trace} = Spectre.Server.Diagnostics.trace(encoded, "interaction-1")

    for {request, expected} <- [
          {[:checkpoint, :operational], operational},
          {[:interaction, "interaction-1"], trace}
        ] do
      assert {:ok, prepared} = ServerTool.prepare(:inspect, request, %{scope: :domain})
      assert {:ok, ^expected} = ServerTool.invoke(:inspect, prepared, context)
      refute inspect(expected) =~ "OWN PRIVATE PAYLOAD"
      refute inspect(expected) =~ "999"
      assert :ok = Spectre.GAM.Canonical.Value.validate(expected)
      assert {:error, :server_checkpoint_required} = ServerTool.invoke(:inspect, prepared, %{})
    end
  end

  @tag :tmp_dir
  test "new projections preserve store errors and reject corrupt checkpoint bytes", %{
    tmp_dir: dir
  } do
    store =
      start_supervised!({Spectre.Ledger.ServerStore, path: Path.join(dir, "invalid.ledger")})

    context = %{
      checkpoint_ref: %{adapter: Spectre.Ledger.ServerStore, store: store, key: :missing}
    }

    for request <- [[:checkpoint, :operational], [:interaction, "interaction-1"]] do
      assert {:ok, prepared} = ServerTool.prepare(:inspect, request, %{})
      assert {:error, :checkpoint_not_found} = ServerTool.invoke(:inspect, prepared, context)
    end

    {:ok, 1} = Spectre.Ledger.ServerStore.put_new(store, :missing, "corrupt")

    for request <- [[:checkpoint, :operational], [:interaction, "interaction-1"]] do
      assert {:ok, prepared} = ServerTool.prepare(:inspect, request, %{})
      assert {:error, _reason} = ServerTool.invoke(:inspect, prepared, context)
    end
  end

  @tag :tmp_dir
  test "malformed nested checkpoint records fail as data errors", %{tmp_dir: dir} do
    store = start_supervised!({Spectre.Ledger.ServerStore, path: Path.join(dir, "nested.ledger")})

    for {entry, index} <- Enum.with_index(["invalid", %{event: :invalid}, %{event: [1, 2]}]) do
      snapshot = %{
        version: 1,
        sequence: 1,
        pending: %{},
        inbox: %{},
        outbox: %{command: entry}
      }

      {:ok, encoded} = Spectre.Server.Checkpoint.encode_value(snapshot)
      {:ok, _} = Spectre.Ledger.ServerStore.put_new(store, index, encoded)

      context = %{
        checkpoint_ref: %{adapter: Spectre.Ledger.ServerStore, store: store, key: index}
      }

      for request <- [[:checkpoint, :operational], [:interaction, "interaction-1"]] do
        {:ok, prepared} = ServerTool.prepare(:inspect, request, %{})
        assert {:error, :not_a_server_checkpoint} = ServerTool.invoke(:inspect, prepared, context)
      end
    end
  end
end
