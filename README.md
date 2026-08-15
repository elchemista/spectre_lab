# Spectre Lab

Spectre Lab 0.1.0 provides verified offline checkpoint playback and isolated
testing tools for Spectre 0.3.2. It consumes the Bundle v1 contract owned by
Spectre Ledger 0.1.x; it does not add an owner, scheduler, storage backend, or
history subsystem to Spectre core.

Lab plays back only checkpoints that Spectre actually persisted. Spectre may
coalesce checkpoint writes, so Lab does **not** claim every runtime revision,
deterministic execution replay, or reproduction of model and external side
effects.

## Installation

```elixir
def deps do
  [
    {:spectre, "~> 0.3.2"},
    {:spectre_ledger,
     github: "elchemista/spectre_ledger",
     ref: "404858a4e1e91716a13219e87bf5308f3efd2395"},
    {:spectre_lab, github: "elchemista/spectre_lab", branch: "main", only: [:dev, :test]}
  ]
end
```

Lab has no PostgreSQL runtime. Ecto SQL and Postgrex are not required by Lab,
and loading a bundle never opens a Ledger backend or starts a Repo.

During development against adjacent checkouts, opt in to each path explicitly:

```console
SPECTRE_PATH=../spectre SPECTRE_LEDGER_PATH=../spectre_ledger mix deps.get
SPECTRE_PATH=../spectre SPECTRE_LEDGER_PATH=../spectre_ledger mix test
```

Merely placing sibling repositories next to Lab does not replace its declared
sources. Spectre is resolved from Hex; Ledger 0.1.0 and Lab 0.1.0 remain
GitHub-only until their maintainers decide they are ready to publish.

## Verified checkpoint playback

```elixir
bundle = File.read!("test/fixtures/account-checkpoints.json")

{:ok, playback} = Spectre.Lab.load(bundle)
[1, 4] = Spectre.Lab.Playback.revisions(playback)
{:ok, frame} = Spectre.Lab.Playback.fetch(playback, 4)
checkpoint_bytes = frame.checkpoint
capture = Spectre.Lab.Playback.completeness(playback)
```

`Spectre.Lab.load/2` delegates decoding and integrity verification to
`Spectre.Ledger.Bundle`. Frames retain opaque checkpoint bytes and verified
Ledger identities; Lab production code does not decode `Spectre.Instance`
Canonical internals or restore executable Runs. Loading also forces Ledger
Bundle telemetry off, including the global `:telemetry` sink; callers may pass
only the documented Bundle resource-limit options.

Bundle v1 is a trusted/local artifact boundary. Spectre Foundation decoding
may load an existing module named by a valid checkpoint, so do not pass
arbitrary untrusted bundles to Lab in an application node. See
[Security](SECURITY.md) for the operational boundary.

Two playbacks for the same stream can be compared by verified checkpoint
identity:

```elixir
{:ok, report} = Spectre.Lab.diff(before_playback, after_playback)
```

The completeness map reports persisted revisions and gaps explicitly. A gap is
not inferred execution history; it only says that intermediate revisions are
absent from the persisted checkpoint chain.

## Boundary receipt playback

Ledger 0.1.0 keeps receipt entries and envelope objects outside Bundle v1.
Fetch a complete chain through Ledger, then detach it into an offline Lab
playback:

```elixir
{:ok, entries} = Spectre.Ledger.receipt_entries(instance_ref, ledger_opts)
{:ok, envelopes} = Spectre.Ledger.receipts(instance_ref, ledger_opts)

{:ok, receipts} = Spectre.Lab.load_receipts(entries, envelopes)
[1, 2, 3] = Spectre.Lab.ReceiptPlayback.sequences(receipts)
terminal = Spectre.Lab.ReceiptPlayback.by_kind(receipts, :inference_attempt_terminal)
```

Loading performs no backend access. Lab re-verifies the complete physical
entry chain and every entry/envelope binding, hashes the stream key in its
verification report, and preserves physical append order. Its completeness
map reports separately whether canonical revisions were ordered and whether
state digests were present. It never claims every revision, deterministic
replay, or exactly-once external effects.

Lab deliberately does not define a receipt bundle format. Until Ledger owns
one, callers must protect the in-memory entries and confidential envelopes and
must not treat two independently paginated queries as a complete chain.

## ExUnit test case

```elixir
defmodule MyApp.AccountPlaybackTest do
  use Spectre.Lab.TestCase, async: true

  test "keeps live I/O closed", %{io_fuse: io_fuse} do
    assert {:error, :live_io_blocked} =
             Spectre.Lab.IOFuse.dispatch(io_fuse, fn -> :network_call end)

    assert :ok = assert_no_live_io(io_fuse, fn -> :ok end)
  end
end
```

Each case receives an unregistered, caller-supervised sandbox and a closed
`Spectre.Lab.IOFuse`. The fuse gates only work explicitly routed through
`IOFuse.dispatch/2`; it is not a universal network, file, process, or adapter
interceptor.

## Virtual streaming inference

Exercise the real Spectre 0.3.2 streaming runtime without opening a provider
connection:

```elixir
script =
  Spectre.Lab.Inference.StreamScript.text!("hello from the fixture",
    chunk_size: 4
  )

{:ok, stream} =
  Spectre.stream(instance, "stream this",
    model: MyApp.TestModel,
    plan_actions?: false,
    stream_adapter: Spectre.Lab.Inference.StreamAdapter,
    stream_adapter_opts: [script: script, observer: self()]
  )

events = Enum.to_list(stream)
```

The adapter is lazy and pull-driven: one consumer demand schedules at most one
scripted transport item in the real session mailbox. Scripts may contain
provider-event batches, `:stall`, or `{:transport_error, reason}` and can split
UTF-8 codepoints exactly like network chunks. Early Enumerable termination
goes through the normal provider cancellation path. The test model is still
needed for immutable selection identity, but its synchronous `complete/2`
callback is never used.

This is deterministic fixture delivery, not deterministic replay of a prior
model call. Restart support resumes only from the explicit
`{:spectre_lab, consumed_items}` cursor stamped on delivered fixture batches.

Generate a safe starter test with:

```console
mix spectre_lab.gen.test MyApp.AccountPlaybackTest
mix spectre_lab.gen.test MyApp.AccountPlaybackTest --path test/contracts --dry-run
```

The generator refuses implicit overwrites, absolute or escaping paths, and
symlinked destination parents.

## Fault injection

`Spectre.Lab.Fault.CheckpointStore` wraps the existing public
`Spectre.Instance.CheckpointStore` boundary. A caller-owned controller consumes
a deterministic FIFO script without timers or global registration:

```elixir
{:ok, controller} =
  Spectre.Lab.Fault.Controller.start_link(
    script: %{
      compare_and_swap: [
        {:fail_before, :unavailable},
        {:commit_then_return, {:error, {:ambiguous, :lost_ack}}}
      ]
    }
  )

store =
  {Spectre.Lab.Fault.CheckpointStore,
   controller: controller,
   delegate: {MyCheckpointStore, namespace: "test"}}
```

The adapter preserves Spectre's existing checkpoint-store normalization and
ambiguity semantics; it does not invent a second persistence contract.

The same controller can inject failures at the Spectre 0.3.2 receipt boundary:

```elixir
receipt_sink =
  {Spectre.Lab.Fault.ReceiptSink,
   controller: controller,
   delegate: {MyReceiptSink, namespace: "test"}}
```

Use the operation keys `:receipt_append`, `:receipt_lookup`,
`:receipt_put_payload`, and `:receipt_get_payload`. Append and payload staging
support committed-but-ambiguous replies, so tests can exercise idempotent
lookup, payload reconciliation, and required-receipt recovery through the same
public contract used in production.

## Diagnostics

```console
mix spectre_lab.doctor
mix spectre_lab.doctor --bundle test/fixtures/account-checkpoints.json --strict
mix spectre_lab.doctor --format json
mix spectre_lab.bundle.verify test/fixtures/account-checkpoints.json --format json
```

Doctor composes the public Spectre Doctor and Stack conformance contracts. It
does not start resources or access a Ledger backend. Bundle file access belongs
to the Mix tasks and is bounded to 64 MiB.

See [Architecture](docs/ARCHITECTURE.md), [Testing](docs/TESTING.md), and the
normative [Public API](docs/PUBLIC_API.md).

## License

Apache-2.0. See the repository `LICENSE` file.
