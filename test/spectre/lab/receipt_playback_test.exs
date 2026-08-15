defmodule SpectreLabReceiptPlaybackTest do
  use Spectre.Lab.TestCase, async: true

  alias Spectre.Lab
  alias Spectre.Lab.ReceiptLoader
  alias Spectre.Lab.ReceiptPlayback
  alias Spectre.Ledger
  alias Spectre.Ledger.Backend.Memory
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink

  test "keeps a complete verified receipt chain usable after its backend stops", context do
    stream_key = unique_stream("offline")
    {server, opts, sink} = receipt_store(context, stream_key)
    first = policy_receipt(stream_key, "run-a", 1)
    second = sample_receipt(stream_key, "run-a", 2)

    assert {:ok, :appended} = Sink.append(sink, first, [])
    assert {:ok, :appended} = Sink.append(sink, second, [])
    assert {:ok, entries} = Ledger.receipt_entries(stream_key, opts)
    assert {:ok, envelopes} = Ledger.receipts(stream_key, opts)

    assert :ok = Spectre.Lab.Sandbox.terminate_child(context.sandbox, server)
    refute Process.alive?(server)

    assert {:ok, playback} = Lab.load_receipts(entries, envelopes)
    assert ReceiptPlayback.sequences(playback) == [1, 2]
    assert ReceiptPlayback.receipts(playback) == [first, second]
    assert {:ok, head} = ReceiptPlayback.head(playback)
    assert head.sequence == 2
    assert {:ok, ^head} = ReceiptPlayback.fetch(playback, 2)
    assert :not_found = ReceiptPlayback.fetch(playback, 3)
    assert [first_frame] = ReceiptPlayback.by_kind(playback, :policy_decision)
    assert first_frame.envelope == first
    assert Enum.map(ReceiptPlayback.for_run(playback, "run-a"), & &1.sequence) == [1, 2]

    assert %{
             capture: :nondeterministic_boundaries,
             physical_order: :verified,
             canonical_ordered: true,
             receipt_count: 2,
             linked_state_count: 1,
             state_linkage: :partial,
             every_revision: false,
             deterministic_replay: false,
             exactly_once_external_effects: false
           } = ReceiptPlayback.completeness(playback)

    assert playback.verification.physical_order == :verified
    assert playback.verification.stream_key_digest == playback.stream_id
    assert byte_size(playback.stream_id) == 64
    refute Map.has_key?(playback.verification, :stream_key)
  end

  test "preserves physical order when canonical revisions arrive out of order", context do
    stream_key = unique_stream("out-of-order")
    {_server, opts, sink} = receipt_store(context, stream_key)
    later = sample_receipt(stream_key, "run-order", 9)
    earlier = sample_receipt(stream_key, "run-order", 4)

    assert {:ok, :appended} = Sink.append(sink, later, [])
    assert {:ok, :appended} = Sink.append(sink, earlier, [])
    assert {:ok, entries} = Ledger.receipt_entries(stream_key, opts)
    assert {:ok, envelopes} = Ledger.receipts(stream_key, opts)

    assert {:ok, playback} = ReceiptLoader.load(entries, envelopes)
    assert ReceiptPlayback.receipts(playback) == [later, earlier]
    refute playback.completeness.canonical_ordered
    assert playback.verification.canonical_ordered == false
  end

  test "rejects broken chains, mismatched envelopes, and noncanonical payloads", context do
    stream_key = unique_stream("invalid")
    {_server, opts, sink} = receipt_store(context, stream_key)
    first = sample_receipt(stream_key, "run-invalid", 1)
    second = sample_receipt(stream_key, "run-invalid", 2)

    assert {:ok, :appended} = Sink.append(sink, first, [])
    assert {:ok, :appended} = Sink.append(sink, second, [])
    assert {:ok, entries} = Ledger.receipt_entries(stream_key, opts)
    assert {:ok, envelopes} = Ledger.receipts(stream_key, opts)

    assert {:error, :invalid_ledger_receipt_chain_start} =
             Lab.load_receipts(Enum.reverse(entries), envelopes)

    assert {:error, {:invalid_lab_receipt_frame, 0, :ledger_receipt_id_mismatch}} =
             Lab.load_receipts(entries, Enum.reverse(envelopes))

    [envelope | rest] = envelopes
    noncanonical = %{envelope | payload: %{changed: true}}

    assert {:error, {:invalid_lab_receipt_frame, 0, :receipt_payload_digest_mismatch}} =
             Lab.load_receipts(entries, [noncanonical | rest])

    assert {:error, :lab_receipt_entry_count_mismatch} =
             Lab.load_receipts(entries, [first])

    assert {:error, :invalid_lab_receipt_playback} = Lab.load_receipts(:invalid, [])
  end

  test "represents an empty verified chain without inventing a stream identity" do
    assert {:ok, playback} = Lab.load_receipts([], [])
    assert playback.stream_id == nil
    assert playback.frames == []
    assert playback.completeness.state_linkage == :none
    assert playback.completeness.receipt_count == 0
    assert ReceiptPlayback.head(playback) == :not_found
    assert ReceiptPlayback.sequences(playback) == []
    assert ReceiptPlayback.by_kind(playback, :policy_decision) == []
    assert ReceiptPlayback.for_run(playback, "missing") == []
  end

  defp receipt_store(context, stream_key) do
    {:ok, server} = start_lab_child(context, {Memory, []})

    opts = [
      backend: :memory,
      server: server,
      namespace: "lab-#{stream_key}"
    ]

    assert {:ok, sink} = Ledger.receipt_sink(opts) |> Sink.normalize()
    {server, opts, sink}
  end

  defp policy_receipt(stream_key, run_id, revision) do
    Envelope.new!(
      kind: :policy_decision,
      instance_ref: stream_key,
      run_id: run_id,
      run_revision: revision,
      canonical_revision: revision,
      correlation_id: "policy-#{run_id}-#{revision}",
      definition_ref: "definition:lab-fixture",
      pre_state_digest: digest(revision),
      post_state_digest: digest(revision + 1),
      payload_schema_ref: "spectre.lab.policy/1",
      payload: %{decision: :allow},
      privacy: :confidential
    )
  end

  defp sample_receipt(stream_key, run_id, revision) do
    Envelope.new!(
      kind: :nondeterminism_sample,
      instance_ref: stream_key,
      run_id: run_id,
      canonical_revision: revision,
      correlation_id: "sample-#{run_id}-#{revision}",
      payload_schema_ref: "spectre.lab.sample/1",
      payload: %{sample: revision},
      privacy: :confidential
    )
  end

  defp digest(value) do
    value
    |> Integer.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unique_stream(label) do
    "instance:lab-#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
