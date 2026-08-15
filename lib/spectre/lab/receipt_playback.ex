defmodule Spectre.Lab.ReceiptPlayback do
  @moduledoc """
  Immutable offline view of a verified Ledger boundary-receipt chain.

  Frames remain in physical append order. `canonical_ordered` in the
  completeness report tells callers whether canonical revisions happened to
  be monotonic; Lab never silently reorders observational evidence.
  """

  alias Spectre.Lab.ReceiptPlayback.Frame
  alias Spectre.Receipt.Envelope

  @enforce_keys [:stream_id, :frames, :verification, :completeness]
  defstruct @enforce_keys

  @type completeness :: %{
          required(:capture) => :nondeterministic_boundaries,
          required(:physical_order) => :verified,
          required(:canonical_ordered) => boolean(),
          required(:receipt_count) => non_neg_integer(),
          required(:linked_state_count) => non_neg_integer(),
          required(:state_linkage) => :none | :partial | :complete,
          required(:kinds) => %{optional(Envelope.kind()) => pos_integer()},
          required(:every_revision) => false,
          required(:deterministic_replay) => false,
          required(:exactly_once_external_effects) => false
        }

  @type t :: %__MODULE__{
          stream_id: String.t() | nil,
          frames: [Frame.t()],
          verification: map(),
          completeness: completeness()
        }

  @doc "Returns physical append sequences in playback order."
  @spec sequences(t()) :: [pos_integer()]
  def sequences(%__MODULE__{frames: frames}), do: Enum.map(frames, & &1.sequence)

  @doc "Returns validated envelopes in physical append order."
  @spec receipts(t()) :: [Envelope.t()]
  def receipts(%__MODULE__{frames: frames}), do: Enum.map(frames, & &1.envelope)

  @doc "Returns the physical receipt-chain head, or `:not_found` for an empty chain."
  @spec head(t()) :: {:ok, Frame.t()} | :not_found
  def head(%__MODULE__{frames: []}), do: :not_found
  def head(%__MODULE__{frames: frames}), do: {:ok, List.last(frames)}

  @doc "Returns one frame by physical append sequence."
  @spec fetch(t(), pos_integer()) :: {:ok, Frame.t()} | :not_found
  def fetch(%__MODULE__{frames: frames}, sequence)
      when is_integer(sequence) and sequence > 0 do
    case Enum.find(frames, &(&1.sequence == sequence)) do
      nil -> :not_found
      frame -> {:ok, frame}
    end
  end

  def fetch(%__MODULE__{}, _sequence), do: :not_found

  @doc "Filters frames by core receipt kind without changing physical order."
  @spec by_kind(t(), Envelope.kind()) :: [Frame.t()]
  def by_kind(%__MODULE__{frames: frames}, kind) when is_atom(kind),
    do: Enum.filter(frames, &(&1.kind == kind))

  def by_kind(%__MODULE__{}, _kind), do: []

  @doc "Filters frames for one Run id without changing physical order."
  @spec for_run(t(), String.t()) :: [Frame.t()]
  def for_run(%__MODULE__{frames: frames}, run_id) when is_binary(run_id) and run_id != "",
    do: Enum.filter(frames, &(&1.envelope.run_id == run_id))

  def for_run(%__MODULE__{}, _run_id), do: []

  @doc "Returns honest capture, ordering, state-linkage, and replay claims."
  @spec completeness(t()) :: completeness()
  def completeness(%__MODULE__{completeness: completeness}), do: completeness
end
