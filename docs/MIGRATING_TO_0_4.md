# Migrate Lab integration from 0.3 to 0.4

This guide targets the current unreleased development branch, not a published
Hex release. Start with the matching Git dependencies in the [README](../README.md).
The package's compatibility requirement is Spectre `~> 0.4.0`; use the core
`feature/agent-server-gam`, Ledger `feature/stack-tools-0.4` and Lab
`feature/diagnostics-0.4` branches together. Lab's own package version is independent
of the core compatibility line; use reviewed commit refs for reproducibility.

## Move ownership, preserve capabilities

| Earlier integration | AgentServer 0.4 |
| --- | --- |
| Instance Bundle playback used as general runtime replay | Keep archive playback separate from AgentServer structural inspection |
| Fetch a checkpoint blob via Ledger, then pass it through Lab | Use `{:inspect, :checkpoint}`; bytes stay inside the worker |
| Successful decoding treated as permission to restore | Loader still validates identity/fingerprint/recovery; GAM still owns authority |
| Lab always scoped to dev/test dependency only | Use runtime dependency when production AgentServer installs the Lab helper |
| Custom code decoding checkpoint internals for an inspector | Use `{:inspect, :checkpoint, :operational}` for own-checkpoint metadata |
| Checkpoint inspection assumed to contain a complete history | Use the interaction trace and check its explicit coverage/missing-history fields |

Keep routes in the Agent and move execution callbacks to
`use Spectre.Server, tools: MyApp.AI`. Return the context produced by `lab`
and handle its tagged result in `handle_result/3`. The
[core migration guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MIGRATING_TO_0_4.md) covers shared Server, GAM and
checkpoint changes; old Instance snapshots are not AgentServer snapshots.

## What remains available

The original `{:inspect, :checkpoint}` summary is unchanged. New helper modes
remain scoped to the caller's trusted checkpoint; choosing a mode cannot inspect
the root or another Skill. For authorized developer inspection, use
`Spectre.Lab.inspect(server, :operational)` or
`Spectre.Lab.trace(server, interaction_id)` from the authenticated application
consumer. These preserve caller identity and delegate access decisions and
versioned projection to the core. They do not replace GAM or add a second journal.

Lab retains offline Instance bundle and boundary-receipt playback, reports and isolated harnesses. Those formats are separate from AgentServer canonical snapshot inspection. Playback never manufactures missing execution history or replays external effects.

See the [retained reference](ARCHIVE_PLAYBACK.md) for these APIs and
[0.4 helper/lifecycle contracts](SPECTRE_0_4.md) for the new integration. Migration
is an ownership/API change, not a promise that every legacy convenience now
implicitly routes through AgentServer or GAM.

## Skill Servers

Mounted Skills share their root's GAM Domain and retain separate checkpoints.
Follow the [core Skill guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md); this package requires no separate
Skill host or second GAM configuration.
