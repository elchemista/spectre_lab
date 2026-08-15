# Changelog

All notable changes to Spectre Lab are documented here.

## 0.1.0

Initial release for Spectre 0.3.2 and Spectre Ledger 0.1.x.

### Added

- bounded, verified loading of the Ledger Bundle v1 format;
- offline bundle loading that suppresses custom and global Ledger telemetry and
  accepts only closed Bundle resource-limit options;
- immutable playback frames containing opaque persisted-checkpoint bytes;
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
