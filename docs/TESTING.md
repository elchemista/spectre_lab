# Testing with Spectre Lab

Lab separates three test concerns: verified persisted-checkpoint fixtures,
caller-owned process isolation, and fault injection at an existing public
boundary.

## Generate a case

```console
mix spectre_lab.gen.test MyApp.PaymentPlaybackTest
```

Use `--path test/contracts` for another project-relative directory,
`--dry-run` to validate without writing, and `--force` only for an intentional
replacement of an existing regular file. The generator never follows a
symlinked destination parent and refuses paths outside the current project.

The generated test uses `Spectre.Lab.TestCase`. Each test receives:

- `sandbox`: an unregistered DynamicSupervisor;
- `io_fuse`: an unregistered I/O fuse that starts closed.

Start test-owned processes with `start_lab_child/2` so ExUnit tears down the
whole supervised unit. Names, registries, ETS tables, external services, and
processes created outside that sandbox remain the caller's responsibility.

## Route side effects explicitly

```elixir
assert {:error, :live_io_blocked} =
         Spectre.Lab.IOFuse.dispatch(io_fuse, fn -> MyHTTP.post(payload) end)

:ok = Spectre.Lab.IOFuse.open(io_fuse)
assert {:ok, response} =
         Spectre.Lab.IOFuse.dispatch(io_fuse, fn -> MyHTTP.post(payload) end)
```

The fuse does not discover or intercept direct I/O. Put `dispatch/2` around the
adapter call being tested, or inject an adapter that does so. The
`assert_no_live_io/2` helper checks synchronous authorizations completed while
its function runs; it is not a proof about unrelated or later asynchronous
work.

## Stream through the real runtime without a provider

Build a `Spectre.Lab.Inference.StreamScript` and select
`Spectre.Lab.Inference.StreamAdapter` in the ordinary `Spectre.stream/3`
options. `text!/2` creates globally sequenced `:started`, `:delta`, `:usage`,
and `:completed` events with cumulative usage. For protocol failures, use
`new!/1` with explicit `ProviderEvent` batches, `:stall`, or
`{:transport_error, reason}`.

Each batch is one transport item and requires one consumer-driven credit.
Delta binaries may split UTF-8 codepoints; Spectre performs the same bounded
reassembly and sanitizer work used for a real adapter. Pass `observer: self()`
to receive text-free opened, demand, and cancellation facts. Cancellation
reasons are reduced to a class before notification.

The script is a deterministic source, not evidence that an earlier provider
execution can be replayed. The adapter never calls `LLM.complete/2`, never
opens a socket, and implements Spectre's bound-fixture conformance callback.
Use `StreamScript.conformance_messages/2` with `delivery: :external` to run the
public `Spectre.Inference.StreamAdapter.Conformance` suite.

## Script checkpoint-store failures

Create a caller-owned `Spectre.Lab.Fault.Controller` and configure
`Spectre.Lab.Fault.CheckpointStore` with the controller plus a delegate store.
Scripts are FIFO lists keyed by public checkpoint-store operation:

```elixir
%{
  load: [{:fail_before, :unavailable}],
  compare_and_swap: [
    :pass,
    {:commit_then_return, {:error, {:ambiguous, :lost_ack}}}
  ]
}
```

Omitted and exhausted operations pass through. `:commit_then_return` first
requires the delegate mutation to return `:ok`, then exposes only Spectre's
ambiguous mutation reply shape. It is rejected for `load`.

The controller also accepts `:receipt_append`, `:receipt_lookup`,
`:receipt_put_payload`, and `:receipt_get_payload`. Wrap a real test sink with
`Spectre.Lab.Fault.ReceiptSink`; committed-but-ambiguous actions are valid only
for append and payload staging. When payload staging loses its acknowledgement,
`Spectre.Receipt.Sink.put_payload/3` performs its ordinary content-addressed
readback through the wrapper, so the test observes production reconciliation
rather than a Lab-specific shortcut.

## Fixture discipline

Capture fixtures through Spectre Ledger's public Entry and Bundle contracts and
verify them before assertions. Application tests should not decode Spectre's
private Canonical checkpoint internals to drive Lab. A playback frame contains
opaque bytes plus the identity fields already verified by Ledger.

Always assert `Spectre.Lab.Playback.completeness/1` when a test depends on
revision coverage. Persisted revision gaps are expected when Spectre coalesces
checkpoint writes; never interpret a gap as reconstructed transition history.

Treat Bundle v1 files as trusted/local test artifacts. Do not load arbitrary
downloads in the application test node because Spectre Foundation decoding may
load an existing module named by checkpoint data.

For receipt assertions, capture a complete `receipt_entries/2` and `receipts/2`
pair from Ledger and pass both to `Spectre.Lab.load_receipts/2`. Query the
result with `ReceiptPlayback.fetch/2`, `by_kind/2`, or `for_run/2`. Frames stay
in physical append order even when observational delivery makes canonical
revisions non-monotonic. Always inspect `ReceiptPlayback.completeness/1` before
making state-linkage or replay claims.

Ledger Bundle v1 contains checkpoints only. Do not serialize a receipt
playback as if Lab had defined another stable wire format; no such format is
part of Lab 0.1.0.

## Project gates

The release suite can run against adjacent Spectre and Ledger 0.3.2 / 0.1.x
checkouts only through explicit path overrides:

```console
SPECTRE_PATH=../spectre SPECTRE_LEDGER_PATH=../spectre_ledger mix deps.get
SPECTRE_PATH=../spectre SPECTRE_LEDGER_PATH=../spectre_ledger mix test
```

Without those variables, even when sibling directories exist, Mix keeps the
declared Spectre `~> 0.3.2` Hex source and Ledger 0.1.0 GitHub source.

Lab tests and bundle consumers require no PostgreSQL service, Ecto Repo, Ecto
SQL, or Postgrex dependency.
