defmodule Spectre.Lab.Diff do
  @moduledoc "Compares verified checkpoint identity without decoding Instance internals."

  alias Spectre.Lab.Diff.Report
  alias Spectre.Lab.Playback

  @doc "Compares two playbacks for the same opaque stream."
  @spec compare(Playback.t(), Playback.t()) :: {:ok, Report.t()} | {:error, term()}
  def compare(%Playback{stream_id: stream_id} = left, %Playback{stream_id: stream_id} = right) do
    left_frames = left.frames
    right_frames = right.frames
    common = common_prefix(left_frames, right_frames)

    {:ok,
     %Report{
       status: status(left_frames, right_frames, common),
       common_prefix_count: common,
       common_head_revision: common_revision(left_frames, common),
       left_revisions: Playback.revisions(left),
       right_revisions: Playback.revisions(right),
       left_only: suffix_revisions(left_frames, common),
       right_only: suffix_revisions(right_frames, common),
       changed_revisions: changed_revisions(left_frames, right_frames)
     }}
  end

  def compare(%Playback{}, %Playback{}), do: {:error, :lab_playback_stream_mismatch}
  def compare(_left, _right), do: {:error, :invalid_lab_playback_diff}

  defp common_prefix(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.take_while(fn {left_frame, right_frame} ->
      left_frame.entry_digest == right_frame.entry_digest
    end)
    |> length()
  end

  defp status(left, right, common) do
    cond do
      common == length(left) and common == length(right) -> :identical
      common == length(left) -> :left_prefix
      common == length(right) -> :right_prefix
      true -> :diverged
    end
  end

  defp common_revision(_frames, 0), do: nil
  defp common_revision(frames, count), do: Enum.at(frames, count - 1).revision

  defp suffix_revisions(frames, common) do
    frames |> Enum.drop(common) |> Enum.map(& &1.revision)
  end

  defp changed_revisions(left, right) do
    right_by_revision = Map.new(right, &{&1.revision, &1})

    left
    |> Enum.filter(fn frame ->
      case Map.get(right_by_revision, frame.revision) do
        nil -> false
        other -> other.checkpoint_digest != frame.checkpoint_digest
      end
    end)
    |> Enum.map(& &1.revision)
  end
end
