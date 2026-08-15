defmodule Spectre.Lab.ReceiptLoader do
  @moduledoc """
  Verifies a complete Ledger receipt chain into an immutable offline playback.

  Lab accepts only already-materialized entries and envelopes. It performs no
  backend query and defines no receipt serialization format. Physical chain
  order is verified independently from canonical revision order because
  observational delivery may append receipts out of canonical order.
  """

  alias Spectre.Lab.ReceiptPlayback
  alias Spectre.Lab.ReceiptPlayback.Frame
  alias Spectre.Ledger.ReceiptChain
  alias Spectre.Ledger.ReceiptEntry
  alias Spectre.Receipt.Envelope

  @doc "Verifies paired physical entries and envelopes without accessing a backend."
  @spec load([ReceiptEntry.t()], [Envelope.t()]) ::
          {:ok, ReceiptPlayback.t()} | {:error, term()}
  def load(entries, envelopes) when is_list(entries) and is_list(envelopes) do
    with true <- length(entries) == length(envelopes),
         {:ok, chain} <- ReceiptChain.verify(entries),
         {:ok, frames} <- frames(entries, envelopes) do
      {:ok,
       %ReceiptPlayback{
         stream_id: stream_id(chain.stream_key),
         frames: frames,
         verification: verification(chain),
         completeness: completeness(chain, frames)
       }}
    else
      false -> {:error, :lab_receipt_entry_count_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def load(_entries, _envelopes), do: {:error, :invalid_lab_receipt_playback}

  defp frames(entries, envelopes) do
    entries
    |> Enum.zip(envelopes)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{entry, envelope}, index}, {:ok, frames} ->
      case frame(entry, envelope, index) do
        {:ok, frame} -> {:cont, {:ok, [frame | frames]}}
        {:error, reason} -> {:halt, {:error, {:invalid_lab_receipt_frame, index, reason}}}
      end
    end)
    |> case do
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      {:error, _reason} = error -> error
    end
  end

  defp frame(%ReceiptEntry{} = entry, %Envelope{} = envelope, index) do
    with {:ok, ^envelope} <- Envelope.new(envelope),
         :ok <- ReceiptEntry.verify_envelope(entry, envelope) do
      {:ok,
       %Frame{
         index: index,
         sequence: entry.sequence,
         receipt_id: entry.receipt_id,
         kind: entry.kind,
         canonical_revision: entry.canonical_revision,
         envelope_digest: entry.envelope_digest,
         payload_ref: entry.payload_ref,
         state_linked?: state_linked?(envelope),
         entry: entry,
         envelope: envelope
       }}
    else
      {:ok, _normalized} -> {:error, :noncanonical_lab_receipt_envelope}
      {:error, _reason} = error -> error
    end
  end

  defp frame(_entry, _envelope, _index), do: {:error, :invalid_ledger_receipt_envelope}

  defp verification(chain) do
    chain
    |> Map.delete(:stream_key)
    |> Map.put(:stream_key_digest, stream_id(chain.stream_key))
    |> Map.put(:physical_order, :verified)
  end

  defp completeness(chain, frames) do
    linked = Enum.count(frames, & &1.state_linked?)

    %{
      capture: :nondeterministic_boundaries,
      physical_order: :verified,
      canonical_ordered: chain.canonical_ordered,
      receipt_count: length(frames),
      linked_state_count: linked,
      state_linkage: state_linkage(linked, length(frames)),
      kinds: chain.kinds,
      every_revision: false,
      deterministic_replay: false,
      exactly_once_external_effects: false
    }
  end

  defp state_linkage(0, _total), do: :none
  defp state_linkage(total, total), do: :complete
  defp state_linkage(_linked, _total), do: :partial

  defp state_linked?(%Envelope{pre_state_digest: pre, post_state_digest: post}),
    do: is_binary(pre) and is_binary(post)

  defp stream_id(nil), do: nil

  defp stream_id(stream_key) when is_binary(stream_key) do
    stream_key
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
