# Changelog

## 0.1.0 — 2026-11-17

### Added

- Current AgentServer checkpoint inspection through the trusted logical checkpoint
  reference, without copying its bytes into helper results.
- Summary, redacted operational and retained-interaction projections using the
  core diagnostic contract; unavailable historical information stays explicit.
- `Spectre.Lab.inspect/3` and `trace/3` delegate authorized live inspection in the
  original caller process, preserving the Server's access checks.

### Changed

- Require Spectre `~> 0.4.0` and Ledger `~> 0.1.0`, with explicit Git/path sources
  for compatible development checkouts. Lab keeps its independent package version.
- Document AgentServer inspection separately from offline archive playback.

### Compatibility

- Preserve the existing summary result and each Skill's own-checkpoint boundary.
- Instance Bundle v1, receipt playback, test sandboxes and fault adapters retain
  their separate contracts. Inspection does not execute or restore saved work.
- PostgreSQL and Ecto remain optional Ledger concerns; Lab requires no database.

## 0.1.0

Initial release for Spectre 0.3.2 and Spectre Ledger 0.1.x.

### Added

- bounded, verified loading of the Ledger Bundle v1 format;
- offline bundle loading that suppresses custom and global Ledger telemetry and
  accepts only closed Bundle resource-limit options;
- immutable playback frames containing opaque persisted-checkpoint bytes;
- offline receipt-chain playback with physical-order verification, paired
  envelope content checks, state-linkage completeness, and kind/Run queries;
- explicit persisted-revision and revision-gap completeness metadata, without
  every-revision or deterministic-replay claims;
- identity-only diff reports for verified playbacks of the same stream;
- caller-owned sandboxes and a fail-closed, explicitly routed I/O fuse;
- a pull-driven virtual inference adapter with finite scripts, cumulative
  usage, UTF-8 fragment support, cancellation, resume cursors, and core
  conformance fixtures;
- an ExUnit case template and safe test generator;
- deterministic fault scripts around Spectre's public checkpoint-store
  behaviour, including ambiguous committed-write simulation;
- the same deterministic fail-before and committed-but-ambiguous scripting for
  Spectre 0.3.2 receipt append, lookup, payload staging, and payload readback;
- read-only Lab Doctor and focused bundle verification Mix tasks;
- explicit, environment-selected local Spectre and Ledger path overrides;
- normative public API, package, documentation, and source release contracts.
