defmodule Spectre.Lab.ReceiptPlayback.Frame do
  @moduledoc """
  One verified boundary receipt in physical Ledger append order.

  The frame retains the complete confidential envelope for explicit test
  assertions. It must be protected like the Ledger artifact from which it was
  obtained.
  """

  alias Spectre.Ledger.ReceiptEntry
  alias Spectre.Receipt.Envelope

  @enforce_keys [
    :index,
    :sequence,
    :receipt_id,
    :kind,
    :canonical_revision,
    :envelope_digest,
    :payload_ref,
    :state_linked?,
    :entry,
    :envelope
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          sequence: pos_integer(),
          receipt_id: String.t(),
          kind: Envelope.kind(),
          canonical_revision: non_neg_integer() | nil,
          envelope_digest: String.t(),
          payload_ref: String.t(),
          state_linked?: boolean(),
          entry: ReceiptEntry.t(),
          envelope: Envelope.t()
        }
end
