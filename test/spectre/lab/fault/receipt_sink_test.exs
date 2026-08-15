defmodule SpectreLabFaultReceiptSinkTest do
  use Spectre.Lab.TestCase, async: true

  alias Spectre.Lab.Fault.Controller
  alias Spectre.Lab.Fault.ReceiptSink, as: FaultSink
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink
  alias Spectre.Receipt.Sink.Conformance
  alias Spectre.Receipt.Sink.Memory

  test "passes all receipt operations through the public sink boundary", context do
    {sink, controller, _server} = fault_sink(context, %{})
    envelope = envelope("pass")

    assert {:ok, :appended} = Sink.append(sink, envelope, trace: :portable)
    assert {:ok, ^envelope} = Sink.lookup(sink, envelope.id, trace: :portable)
    assert {:ok, payload_ref} = Sink.put_payload(sink, envelope, trace: :portable)
    assert {:ok, ^envelope} = Sink.get_payload(sink, payload_ref, trace: :portable)

    assert %{
             calls: %{
               receipt_append: 1,
               receipt_lookup: 1,
               receipt_put_payload: 1,
               receipt_get_payload: 1
             },
             actions: %{pass: 4}
           } = Controller.snapshot(controller)
  end

  test "fails before append without mutating the delegate", context do
    script = %{receipt_append: [{:fail_before, :injected_unavailable}]}
    {sink, controller, _server} = fault_sink(context, script)
    envelope = envelope("append-failure")

    assert {:error, {:receipt_sink_error, :injected_unavailable}} =
             Sink.append(sink, envelope, [])

    assert :not_found = Sink.lookup(sink, envelope.id, [])
    assert %{actions: %{fail_before: 1, pass: 1}} = Controller.snapshot(controller)
  end

  test "commits append and then exposes an ambiguous lost acknowledgement", context do
    script = %{
      receipt_append: [
        {:commit_then_return, {:error, {:ambiguous, :injected_append_ack_lost}}}
      ]
    }

    {sink, controller, _server} = fault_sink(context, script)
    envelope = envelope("append-ambiguous")

    assert {:error, {:ambiguous, :injected_append_ack_lost}} =
             Sink.append(sink, envelope, [])

    assert {:ok, ^envelope} = Sink.lookup(sink, envelope.id, [])
    assert %{actions: %{commit_then_return: 1}} = Controller.snapshot(controller)
  end

  test "lets the core reconcile a committed payload after an ambiguous reply", context do
    script = %{
      receipt_put_payload: [
        {:commit_then_return, {:error, {:ambiguous, :injected_payload_ack_lost}}}
      ]
    }

    {sink, controller, _server} = fault_sink(context, script)
    envelope = envelope("payload-ambiguous")
    expected_ref = Sink.payload_ref(envelope)

    assert {:ok, ^expected_ref} = Sink.put_payload(sink, envelope, [])
    assert {:ok, ^envelope} = Sink.get_payload(sink, expected_ref, [])

    assert %{
             calls: %{receipt_put_payload: 1, receipt_get_payload: 2},
             actions: %{commit_then_return: 1, pass: 2}
           } = Controller.snapshot(controller)
  end

  test "runs the core receipt-sink conformance suite through the fault adapter", context do
    {sink, _controller, _server} = fault_sink(context, %{})

    assert {:ok,
            %{
              append: :verified,
              idempotency: :verified,
              lookup: :verified,
              payload_store: :verified
            }} = Conformance.run(sink)
  end

  test "validates receipt scripts and reserved adapter options", context do
    assert {:error, :invalid_checkpoint_fault_script} =
             Controller.start_link(
               script: %{
                 receipt_lookup: [
                   {:commit_then_return, {:error, {:ambiguous, :not_a_mutation}}}
                 ]
               }
             )

    {:ok, controller} = start_lab_child(context, {Controller, []})
    envelope = envelope("invalid-config")

    assert {:error, {:invalid_fault_receipt_sink, {:missing_option, :delegate}}} =
             FaultSink.append(envelope, controller: controller)

    assert {:error, {:invalid_fault_receipt_sink, :invalid_option}} =
             FaultSink.append(envelope,
               controller: controller,
               delegate: {FaultSink, []}
             )

    assert {:error, :invalid_fault_receipt_id} = FaultSink.lookup("", [])
    assert {:error, :invalid_fault_receipt_payload_ref} = FaultSink.get_payload("", [])
  end

  defp fault_sink(context, script) do
    {:ok, server} = start_lab_child(context, {Memory, []})
    {:ok, controller} = start_lab_child(context, {Controller, script: script})

    sink = {FaultSink, controller: controller, delegate: {Memory, server: server}}
    assert {:ok, {_module, _opts}} = Sink.normalize(sink)

    {sink, controller, server}
  end

  defp envelope(label) do
    Envelope.new!(
      kind: :nondeterminism_sample,
      correlation_id: "lab-receipt-#{label}",
      payload_schema_ref: "spectre.lab.receipt-fixture/1",
      payload: %{label: label},
      privacy: :internal
    )
  end
end
