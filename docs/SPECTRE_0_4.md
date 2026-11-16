# Lab with Spectre 0.4 AgentServer

[README](../README.md) · [Migration](MIGRATING_TO_0_4.md) · [Public API](PUBLIC_API.md)

## Helper contract

| Input | Behaviour |
| --- | --- |
| `{:inspect, :checkpoint}` | Fetch current Server checkpoint through its trusted runtime reference inside the worker |
| `{:inspect, :checkpoint, :summary}` | Explicit spelling for the unchanged summary |
| `{:inspect, :checkpoint, :operational}` | Core-versioned redacted operational projection of that same checkpoint |
| `{:inspect, :interaction, interaction_id}` | Partial trace of retained facts for an interaction in that same checkpoint |
| `{:inspect, encoded_binary}` | Inspect explicit offline canonical input within the 1 MiB helper budget |

The summary result is `{:ok, %{codec_valid: true, version: integer, sequence: integer,
pending: count, inbox: count, outbox: count, fingerprint_present: boolean}}`.
The summary exposes counts only; payloads, history, raw checkpoint bytes and
fingerprint contents are not returned. It validates scalar summary fields as well
as the canonical representation. A missing Store returns
`:server_checkpoint_required`; an absent snapshot returns `:checkpoint_not_found`;
a different canonical value is `:not_a_server_checkpoint`.

The logical form receives its Store/module/key from the actual Server checkpoint
configuration. Input cannot select another conversation, supply a live handle,
or override that reference through service options. There is no `bind:` or
execution operation: Lab's helper is cognitive inspection, not a replay executor.

## Operational and trace projections

Operational inspection delegates projection to `Spectre.Server.Diagnostics`.
The core owns the schema and redaction contract; Lab does not couple its public
output to arbitrary internal checkpoint fields. This is checkpoint state, not
a guarantee that the running Server still has exactly that state. The projection
identifies its source, revision/sequence where available and bounded retained
metadata. Multiple active commands and pending intentions may coexist.

The interaction helper correlates retained checkpoint entries by interaction and
command identity. It declares partial coverage and missing history rather than
inferring routing decisions or completed events that were not retained. Unknown
information is distinct from a count of zero. A checkpoint trace is not a complete
GAM authority history and does not reconstruct the model's reasoning.

Both forms use the calling runtime's framework-supplied `checkpoint_ref`.
There is no input for another Server PID, Store/key, mount or privilege level.
Installed Skills share their Agent's GAM Domain but that alone grants no right to
inspect one another. The core projection uses bounded allowlisted metadata; Lab
never copies assigns, user text, prompts, action arguments or raw failure details
into the result. The existing descriptor's 1 MiB result boundary still applies.

### Authorized developer-facing inspection

```elixir
# Run from the authenticated consumer; options are validated by the Server.
Spectre.Lab.inspect(server, :operational, limit: 50)
Spectre.Lab.trace(server, interaction_id, limit: 50)
```

`inspect/3` delegates to `Spectre.Server.inspect/2`; `trace/3` delegates to
`Spectre.Server.trace/3`. No proxy process replaces the actual caller. The Server
checks access before reading state or GAM data, and mode/options cannot confer
authority. Unsupported inspection modes return `{:error, :invalid_lab_inspection_mode}`.
The default limit and maximum are 50 and 100 in the core diagnostic contract.
Direct trace results can correlate the authorized GAM projection with retained
runtime records, while keeping their provenance and coverage explicit.

Lab adds no journal, event owner, polling loop or executor. Runtime/checkpoint
metadata remains the core's responsibility, persistence remains the Store's,
and GAM facts remain the kernel's authority record.

## Resource lifecycle

Lab starts no owner, scheduler, persistence process or external service. Install
Ledger as its declared package dependency, then configure the Server's checkpoint
port using Ledger ServerStore or another supported Store. Both processes remain
under the host's supervision. See [Ledger's 0.4 guide](https://github.com/elchemista/spectre_ledger/blob/feature/stack-tools-0.4/docs/SPECTRE_0_4.md).

If the host wants a periodic inspection, a normal Server callback can return the
same helper command; there is no need for a second Lab event loop. The result
belongs to that command's continuation and can be presented to the user according
to the application's disclosure policy. Inspecting structural data does not prove
that the user is allowed to see arbitrary saved content; the helper deliberately
avoids returning that content.

## Inspection, loading and execution are different operations

`codec_valid` is not proof of Agent definition compatibility, trusted identity,
a valid mandate, or correct recovery state. The AgentServer loader independently
validates fingerprint, identity and recovery invariants before it resumes work.
Do not use Lab output to bypass those checks or manufacture confirmation evidence.

The canonical binary form is for explicitly supplied offline data. Prefer the
logical reference for a running Server: `ledger(:head)` no longer returns a raw
blob, and copying a checkpoint into an inbox just to inspect it would duplicate
conversation state unnecessarily.

## Retained archive and testing APIs

`Spectre.Lab.load/2`, Playback, ReceiptPlayback, diff/report and isolated harness
APIs retain the Instance archive contracts described in
[archive playback](ARCHIVE_PLAYBACK.md) and [testing](TESTING.md). Those APIs verify
what was recorded; they do not reproduce missing revisions, model calls or
external effects. Foundation/Bundle module-loading boundaries remain documented
in [Security](../SECURITY.md). Lab has no PostgreSQL runtime dependency and does
not open a Repo simply to read an offline bundle.

## Mounted Skill runtimes

Use `lab` in Skill Server callbacks with the same installed Stack. Each mount
keeps its own state and checkpoint while sharing the root GAM Domain; mounting
does not grant authority. Inspection uses the calling Server checkpoint and cannot select a sibling or root checkpoint. See the
[core Skill ownership guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md).

## Command lifecycle

Return the context containing the helper command and receive its tagged result
in `handle_result/3`. Invalid input is reported as
`{:error, {:tool_rejected, tool, operation, reason}}`. Recovery and acquired results
remain scoped to the original command; native package calls outside the Server
retain their own host boundary. See the
[Server lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md) and
[Managed GAM guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md).
