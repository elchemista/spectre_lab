defmodule Spectre.Lab.Playback do
  @moduledoc """
  Verified offline timeline of checkpoints persisted by Spectre Ledger.

  A playback is immutable and performs no storage or live adapter calls.
  Revision gaps are reported because Spectre may coalesce checkpoint writes.
  """

  alias Spectre.Lab.Playback.Frame

  @enforce_keys [:stream_id, :frames, :verification, :completeness]
  defstruct @enforce_keys

  @type gap :: %{
          required(:after_revision) => non_neg_integer(),
          required(:checkpoint_revision) => non_neg_integer(),
          required(:uncaptured_count) => pos_integer()
        }

  @type completeness :: %{
          required(:capture) => :persisted_checkpoints,
          required(:capability) => :checkpoint_playback,
          required(:every_revision) => false,
          required(:deterministic_replay) => false,
          required(:persisted_revisions) => [non_neg_integer()],
          required(:revision_gaps) => [gap()]
        }

  @type t :: %__MODULE__{
          stream_id: String.t(),
          frames: [Frame.t()],
          verification: map(),
          completeness: completeness()
        }

  @doc "Returns persisted revisions in playback order."
  @spec revisions(t()) :: [non_neg_integer()]
  def revisions(%__MODULE__{frames: frames}), do: Enum.map(frames, & &1.revision)

  @doc "Returns the final verified frame."
  @spec head(t()) :: {:ok, Frame.t()}
  def head(%__MODULE__{frames: frames}), do: {:ok, List.last(frames)}

  @doc "Returns the frame for one persisted revision."
  @spec fetch(t(), non_neg_integer()) :: {:ok, Frame.t()} | :not_found
  def fetch(%__MODULE__{frames: frames}, revision)
      when is_integer(revision) and revision >= 0 do
    case Enum.find(frames, &(&1.revision == revision)) do
      nil -> :not_found
      frame -> {:ok, frame}
    end
  end

  def fetch(%__MODULE__{}, _revision), do: :not_found

  @doc "Returns the opaque checkpoint bytes at a persisted revision."
  @spec checkpoint(t(), non_neg_integer()) :: {:ok, binary()} | :not_found
  def checkpoint(%__MODULE__{} = playback, revision) do
    with {:ok, frame} <- fetch(playback, revision), do: {:ok, frame.checkpoint}
  end

  @doc "Returns honest capture and replay capability metadata."
  @spec completeness(t()) :: completeness()
  def completeness(%__MODULE__{completeness: completeness}), do: completeness
end
