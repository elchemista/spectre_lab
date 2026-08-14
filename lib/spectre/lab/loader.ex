defmodule Spectre.Lab.Loader do
  @moduledoc """
  Loads a bounded Ledger bundle into an offline checkpoint playback.

  Verification is delegated to the package that owns the format,
  `Spectre.Ledger.Bundle`. Lab never opens a Ledger backend or PostgreSQL Repo.
  Bundle verification may load modules named by a valid Spectre checkpoint, so
  v1 accepts only artifacts from a trusted code environment.
  """

  alias Spectre.Lab.Playback
  alias Spectre.Lab.Playback.Frame
  alias Spectre.Ledger.Bundle

  @limit_keys [
    :max_bytes,
    :max_entries,
    :max_objects,
    :max_object_bytes,
    :max_total_object_bytes,
    :max_depth
  ]

  @doc "Verifies a bundle and constructs an immutable offline playback."
  @spec load(binary() | Bundle.t(), keyword()) :: {:ok, Playback.t()} | {:error, term()}
  def load(bundle, opts \\ []) do
    with {:ok, bundle_opts} <- options(opts),
         {:ok, decoded} <- decode(bundle, bundle_opts),
         {:ok, verification} <- Bundle.verify(decoded, bundle_opts),
         {:ok, frames} <- frames(decoded) do
      {:ok,
       %Playback{
         stream_id: verification.stream_key_digest,
         frames: frames,
         verification: verification,
         completeness: completeness(frames)
       }}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_lab_loader_options}

        Enum.any?(keys, &(&1 not in @limit_keys)) ->
          {:error, :unknown_lab_loader_options}

        true ->
          # Lab playback is an offline/read-only operation. Suppress both the
          # optional handler and the global :telemetry sink owned by Ledger.
          {:ok, [telemetry: false] ++ opts}
      end
    else
      {:error, :invalid_lab_loader_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_lab_loader_options}

  defp decode(%Bundle{} = bundle, _opts), do: {:ok, bundle}
  defp decode(encoded, opts) when is_binary(encoded), do: Bundle.decode(encoded, opts)
  defp decode(_bundle, _opts), do: {:error, :invalid_lab_bundle}

  defp frames(bundle) do
    bundle.entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      checkpoint = Map.fetch!(bundle.objects, entry.blob_digest)

      %Frame{
        index: index,
        entry: entry,
        revision: entry.revision,
        expected_revision: entry.expected_revision,
        checkpoint_digest: entry.checkpoint_digest,
        blob_digest: entry.blob_digest,
        entry_digest: entry.entry_digest,
        checkpoint: checkpoint
      }
    end)
    |> then(&{:ok, &1})
  end

  defp completeness(frames) do
    revisions = Enum.map(frames, & &1.revision)

    %{
      capture: :persisted_checkpoints,
      capability: :checkpoint_playback,
      every_revision: false,
      deterministic_replay: false,
      persisted_revisions: revisions,
      revision_gaps: revision_gaps(frames)
    }
  end

  defp revision_gaps(frames) do
    Enum.flat_map(frames, fn frame ->
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
  end
end
