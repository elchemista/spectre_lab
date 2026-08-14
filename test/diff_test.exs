defmodule SpectreLab.DiffTest do
  use ExUnit.Case, async: false

  alias Spectre.Lab
  alias Spectre.Lab.Diff
  alias Spectre.Lab.Playback
  alias Spectre.Ledger.Backend.Memory
  alias SpectreLab.PublicFixture

  test "classifies identical and prefix timelines by verified entry identity" do
    server = start_supervised!(Memory)
    %{bundles: [first, second]} = PublicFixture.timeline!(server, "prefix")
    {:ok, left} = Lab.load(first)
    {:ok, right} = Lab.load(second)

    assert {:ok, identical} = Lab.diff(left, left)
    assert identical.status == :identical
    assert identical.common_prefix_count == length(left.frames)
    assert identical.left_only == []
    assert identical.right_only == []

    assert {:ok, extension} = Diff.compare(left, right)
    assert extension.status == :left_prefix
    assert extension.common_prefix_count == length(left.frames)
    assert extension.common_head_revision == List.last(Playback.revisions(left))
    assert extension.left_only == []

    assert extension.right_only ==
             Playback.revisions(right) -- Playback.revisions(left)

    assert {:ok, reverse} = Diff.compare(right, left)
    assert reverse.status == :right_prefix
  end

  test "reports divergence and rejects unrelated streams" do
    left_server = start_supervised!({Memory, []}, id: :left_memory)
    right_server = start_supervised!({Memory, []}, id: :right_memory)

    %{common: common_encoded, left: left_encoded, right: right_encoded} =
      PublicFixture.divergent!(left_server, right_server, "divergent")

    %{bundles: [_first, other_encoded]} = PublicFixture.timeline!(right_server, "other")
    {:ok, common} = Lab.load(common_encoded)
    {:ok, left} = Lab.load(left_encoded)
    {:ok, divergent} = Lab.load(right_encoded)
    {:ok, other} = Lab.load(other_encoded)

    assert {:error, :lab_playback_stream_mismatch} = Diff.compare(left, other)

    left_head = List.last(left.frames)
    right_head = List.last(divergent.frames)
    assert left_head.revision == right_head.revision
    refute left_head.checkpoint_digest == right_head.checkpoint_digest
    refute left_head.entry_digest == right_head.entry_digest

    assert {:ok, report} = Diff.compare(left, divergent)
    assert report.status == :diverged
    assert report.common_prefix_count == length(common.frames)
    assert report.common_prefix_count < length(left.frames)

    divergent_revisions =
      left.frames
      |> Enum.drop(report.common_prefix_count)
      |> Enum.map(& &1.revision)

    assert report.changed_revisions == divergent_revisions
    assert report.left_only == divergent_revisions
    assert report.right_only == divergent_revisions

    assert {:error, :invalid_lab_playback_diff} = Diff.compare(left, :invalid)
  end
end
