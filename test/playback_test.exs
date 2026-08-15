defmodule SpectreLab.PlaybackTest do
  use ExUnit.Case, async: false

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Lab
  alias Spectre.Lab.Loader
  alias Spectre.Lab.Playback
  alias Spectre.Ledger.Backend.Memory
  alias Spectre.Ledger.Bundle
  alias Spectre.Stack.Conformance, as: StackConformance
  alias Spectre.Stack.Installable
  alias SpectreLab.PublicFixture

  @bundle_fixture Path.expand("fixtures/ledger-bundle-v1.json.base64", __DIR__)

  test "keeps the frozen legacy-checkpoint Bundle v1 fixture readable" do
    encoded =
      @bundle_fixture
      |> File.read!()
      |> String.replace(~r/\s+/, "")
      |> Base.decode64!()

    {:ok, decoded_fixture} = Bundle.decode(encoded)
    fixture_entry = hd(decoded_fixture.entries)
    fixture_checkpoint = Map.fetch!(decoded_fixture.objects, fixture_entry.blob_digest)

    assert {:ok, %{digest: checkpoint_digest}} =
             Foundation.verify_instance_checkpoint(fixture_checkpoint, fixture_entry.stream_key)

    assert checkpoint_digest == fixture_entry.checkpoint_digest

    assert {:ok, _report} = Bundle.verify(decoded_fixture)

    assert {:ok, playback} = Lab.load(encoded)
    assert [0] = Playback.revisions(playback)
    assert playback.verification.bundle_version == 1

    assert playback.verification.checksum ==
             "93de5aa696ed3fbae449df01eddbc4fb651cb02ed14861e7e1c7c6fd5e27ae5b"

    assert %{capability: :checkpoint_playback, deterministic_replay: false} =
             Playback.completeness(playback)
  end

  test "loads a fully verified bundle into an honest opaque checkpoint timeline" do
    server = start_supervised!(Memory)
    %{bundles: [_first, encoded]} = PublicFixture.timeline!(server, "playback")

    assert {:ok, playback} = Lab.load(encoded)
    revisions = Playback.revisions(playback)
    assert length(revisions) >= 2
    assert revisions == Enum.sort(revisions)

    assert {:ok, head} = Playback.head(playback)
    assert head.revision == List.last(revisions)
    assert {:ok, ^head} = Playback.fetch(playback, head.revision)
    assert :not_found = Playback.fetch(playback, head.revision + 1)
    assert :not_found = Playback.fetch(playback, -1)
    assert {:ok, head.checkpoint} == Playback.checkpoint(playback, head.revision)
    assert :not_found = Playback.checkpoint(playback, head.revision + 1)

    completeness = Playback.completeness(playback)
    assert completeness.capture == :persisted_checkpoints
    assert completeness.capability == :checkpoint_playback
    refute completeness.every_revision
    refute completeness.deterministic_replay
    assert completeness.persisted_revisions == revisions

    assert completeness.revision_gaps ==
             Enum.flat_map(playback.frames, fn frame ->
               missing = frame.revision - frame.expected_revision - 1

               if missing > 0 do
                 [
                   %{
                     after_revision: frame.expected_revision,
                     checkpoint_revision: frame.revision,
                     uncaptured_count: missing
                   }
                 ]
               else
                 []
               end
             end)

    assert Enum.all?(playback.frames, fn frame ->
             frame.checkpoint_digest == frame.entry.checkpoint_digest and
               frame.blob_digest == frame.entry.blob_digest and
               frame.entry_digest == frame.entry.entry_digest
           end)
  end

  test "accepts a decoded Ledger bundle and delegates all corruption and limit checks" do
    server = start_supervised!(Memory)
    %{bundles: [encoded]} = PublicFixture.timeline!(server, "decoded", ["decoded"])
    assert {:ok, decoded} = Bundle.decode(encoded)
    assert {:ok, from_bytes} = Loader.load(encoded)
    assert {:ok, from_struct} = Loader.load(decoded)
    assert from_bytes == from_struct

    assert {:error, {:ledger_bundle_too_large, 8}} = Loader.load(encoded, max_bytes: 8)
    assert {:error, :invalid_lab_bundle} = Loader.load(:not_a_bundle)

    corrupt = encoded |> Jason.decode!() |> Map.put("checksum", String.duplicate("0", 64))

    assert {:error, :ledger_bundle_checksum_mismatch} =
             corrupt |> Jason.encode!() |> Loader.load()
  end

  test "playback remains offline after both the Instance and Ledger backend are stopped" do
    server = start_supervised!(Memory)

    %{bundles: [encoded], instance: instance} =
      PublicFixture.timeline!(server, "offline", ["offline"])

    refute Process.alive?(instance)
    assert :ok = stop_supervised(Memory)
    refute Process.alive?(server)

    assert {:ok, playback} = Lab.load(encoded)
    assert [_revision | _rest] = Playback.revisions(playback)
    assert {:ok, _head} = Playback.head(playback)
  end

  test "offline loading suppresses Ledger telemetry and keeps observability options closed" do
    Code.ensure_loaded!(Spectre.Telemetry)
    target = {Spectre.Telemetry, :emit, 4}
    :erlang.trace_pattern(target, true, [:local])
    :erlang.trace(self(), true, [:call])

    try do
      bundle = PublicFixture.static_bundle!()
      assert {:ok, _playback} = Lab.load(bundle)
      refute_received {:trace, _pid, :call, {Spectre.Telemetry, :emit, _arguments}}

      assert {:error, :unknown_lab_loader_options} = Lab.load(bundle, telemetry: true)

      assert {:error, :unknown_lab_loader_options} =
               Lab.load(bundle, telemetry_handler: fn _, _, _ -> :ok end)

      assert {:error, :invalid_lab_loader_options} = Lab.load(bundle, :invalid)
      assert {:error, :invalid_lab_loader_options} = Lab.load(bundle, [:not_a_keyword])

      assert {:error, :duplicate_lab_loader_options} =
               Lab.load(bundle, max_bytes: 1_024, max_bytes: 2_048)
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(target, false, [:local])
    end
  end

  test "publishes an honest Stack package compatible with Ledger" do
    assert Lab.version() == "0.1.0"
    assert {:ok, report} = StackConformance.run([Spectre.Ledger, Lab])
    assert report.package_count == 2

    assert {:ok, package} = Installable.verify(Lab)
    assert package.requires == [{:package, :spectre_ledger, "~> 0.1.0"}]
    assert package.metadata.capability == :checkpoint_playback
    refute package.metadata.every_revision
    refute package.metadata.deterministic_replay
  end
end
