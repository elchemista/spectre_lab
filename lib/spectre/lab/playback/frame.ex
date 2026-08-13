defmodule Spectre.Lab.Playback.Frame do
  @moduledoc """
  One verified, immutable checkpoint in an offline playback timeline.

  The checkpoint stays opaque. Lab does not decode Instance internals or
  restore executable Runs from a frame.
  """

  alias Spectre.Ledger.Entry

  @enforce_keys [
    :index,
    :entry,
    :revision,
    :expected_revision,
    :checkpoint_digest,
    :blob_digest,
    :entry_digest,
    :checkpoint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          entry: Entry.t(),
          revision: non_neg_integer(),
          expected_revision: non_neg_integer(),
          checkpoint_digest: String.t(),
          blob_digest: String.t(),
          entry_digest: String.t(),
          checkpoint: binary()
        }
end
