# Architecture

Spectre Lab is an offline consumer and test toolkit around contracts already
owned by Spectre and Spectre Ledger. It adds no history records, scheduler,
runtime owner, checkpoint format, storage backend, or replay engine to core.

## Ownership

- Spectre owns Instances, runtime transitions, checkpoint production,
  checkpoint timing, recovery, and the Foundation checkpoint verifier.
- Spectre Ledger implements `Spectre.Instance.CheckpointStore`, owns Entry and
  Bundle v1, and verifies persisted checkpoint chains and objects.
- Lab consumes a verified Bundle v1 as an immutable checkpoint playback and
  supplies caller-owned testing helpers.
- The host owns bundle provenance, authorization, fixture capture, code-path
  isolation, test adapter selection, and all process supervision outside a Lab
  sandbox.

Lab production modules do not use Spectre's private Canonical checkpoint
internals. They keep checkpoint bytes opaque and use Ledger Entry fields as the
verified identity and revision contract.

## Loading pipeline

`Spectre.Lab.load/2` accepts encoded bundle bytes or a decoded
`Spectre.Ledger.Bundle` value:

1. Ledger decodes encoded bytes with its Bundle v1 limits.
2. Ledger verifies the envelope checksum, closed object set, entry chain, raw
   object digests, and public Spectre Foundation checkpoint identity.
3. Lab creates one immutable `Spectre.Lab.Playback.Frame` per persisted entry.
4. Lab derives a completeness map from persisted and expected revisions.

Lab does not open a Ledger backend, import a bundle, query PostgreSQL, or
restore a live Instance or executable Run during this pipeline.
It invokes Bundle decoding and verification with `telemetry: false`, so neither
custom callbacks nor global `:telemetry` handlers are part of offline loading.

Foundation verification decodes the checkpoint and may load an existing module
named by encoded data. Consequently Bundle v1 remains a trusted/local artifact
boundary for Lab 0.1.x even though Ledger applies resource limits and verifies
content integrity.

## Playback semantics

A playback is a finite view of the complete checkpoint chain included in one
verified bundle. It supports ordered revisions, head and revision lookup,
opaque checkpoint retrieval, and comparison with another verified playback of
the same stream.

Spectre's checkpoint manager may coalesce writes. `expected_revision` and
`revision` can therefore expose gaps, and the Bundle v1 manifest permanently
declares:

- capture: `persisted_checkpoints`;
- completeness: `checkpoint_playback`;
- every revision: `false`;
- deterministic replay claim: `false`.

Playback does not reproduce model calls, adapter effects, process scheduling,
messages, clocks, randomness, or transitions that were not persisted. Diff
compares entry and checkpoint identities; it does not infer semantic changes
inside checkpoint bytes.

## Test toolkit

`Spectre.Lab.TestCase` creates an unregistered DynamicSupervisor sandbox and a
closed I/O fuse for every ExUnit test. Children explicitly started under the
sandbox are caller-supervised and terminate with the case.

The I/O fuse is an atomic authorization gate, not an interceptor. Only a
zero-arity function passed to `Spectre.Lab.IOFuse.dispatch/2` is gated and
counted. Closing the fuse after a dispatch was authorized does not revoke work
already running.

`Spectre.Lab.Fault.CheckpointStore` is an adapter at the existing
`Spectre.Instance.CheckpointStore` behaviour. Its unregistered controller
serializes FIFO actions for `load`, `compare_and_swap`, and
`migrate_instance_key`. A committed-but-ambiguous response is available only
for mutation operations and preserves Spectre's public ambiguity reply shape.

`Spectre.Lab.Fault.ReceiptSink` applies the same script model to the four
callbacks owned by `Spectre.Receipt.Sink`. Read faults happen before delegate
access. Append and payload staging can commit through the real delegate and
then return an ambiguous lost acknowledgement, allowing the core's normal
lookup and content-addressed payload reconciliation paths to run unchanged.

## Dependency boundary

Lab depends on Spectre `~> 0.3.2`, Spectre Ledger `~> 0.1.0`, and Jason. Ecto
SQL and Postgrex are neither direct nor required transitive dependencies. Lab
does not select Ledger's optional PostgreSQL backend or supervise an Ecto Repo.
Spectre resolves from Hex. Ledger remains an explicit, commit-pinned GitHub
dependency until its maintainer publishes version 0.1.0; an adjacent checkout
is selected only through `SPECTRE_LEDGER_PATH`.
