# Lab with Spectre 0.4 AgentServer

[README](../README.md) · [Migration](MIGRATING_TO_0_4.md) · [Public API](PUBLIC_API.md)

## Helper contract

| Input | Behaviour |
| --- | --- |
| `{:inspect, :checkpoint}` | Fetch current Server checkpoint through its trusted runtime reference inside the worker |
| `{:inspect, encoded_binary}` | Inspect explicit offline canonical input within the 1 MiB helper budget |

The result is `{:ok, %{codec_valid: true, version: integer, sequence: integer,
pending: count, inbox: count, outbox: count, fingerprint_present: boolean}}`.
The worker exposes counts only; payloads, history, raw checkpoint bytes and
fingerprint contents are not returned. It validates scalar summary fields as well
as the canonical representation. A missing Store returns
`:server_checkpoint_required`; an absent snapshot returns `:checkpoint_not_found`;
a different canonical value is `:not_a_server_checkpoint`.

The logical form receives its Store/module/key from the actual Server checkpoint
configuration. Input cannot select another conversation, supply a live handle,
or override that reference through service options. There is no `bind:` or
execution operation: Lab's helper is cognitive inspection, not a replay executor.

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

## Who owns the loop

`Spectre.Stack` installs immutable capabilities and tool descriptors. The Agent
selects that Stack and declares routing; `Spectre.Server` owns the GenServer,
conversation, pending continuations and asynchronous results. Use
`use Spectre.Server, tools: MyApp.AI` to generate private helpers. A helper returns
an updated context containing a command; return that context from the callback.
It does not synchronously return the package's result. Tuple input chooses the
operation, and `on_result:` identifies the continuation in `handle_result/3`.

Preparation validates ordinary input before dispatch. The Server records command
identity/outbox state, invokes a worker, projects a bounded portable result and
acquires that result before the callback. Durable recovery needs a configured
checkpoint Store. Keep live clients and process handles in supervised resources
or process-local private context, not durable assigns. Native OTP callbacks remain
available; they use the same command-return boundary.

## Where GAM intervenes

The [Governed Act Model](https://spectre.guide/en/governed-act-model) separates
authority (Mandate), supporting facts (Evidence), the admitted execution record
(Act), and unresolved obligations (Duty). Installing a package connects a
capability; it does not grant authority to act on behalf of the end user.

A cognitive descriptor uses the tool worker path, without treating every model
call or classifier as a consent request. A governed descriptor becomes `propose`
before dispatch and uses the standard `Spectre.Server.GAM` bridge. Host-declared
surfaces still determine which effects, protected disclosures or resource uses
need governance; read-oriented operations are not categorically exempt from those
application boundaries. Ordinary configured cognition is not automatically a new
end-user authorization ceremony.

The host supplies a real GAM scope, Candidate factories, mandates/evidence,
Presentations or interpretation when needed, and admitted executors. `bind:` names
that host operation only. Native package calls outside the Server do not acquire
these guarantees automatically. Do not call an effect executor directly from a
flow callback and describe that call as governed.

## Recovery and errors

These packages' cognitive helper operations declare safe replay; the runtime can
retry interrupted cognitive work according to the command lifecycle. A result is
still scoped to its original command. Application input rejections arrive as
`{:error, {:tool_rejected, tool, operation, reason}}`; library domain errors retain
the package's tagged result. Invalid installation/configuration is a developer
error, not a successful acquisition. The general `{:tool_unknown, details}` result
belongs to nonrepeatable tool operations; it is not an instruction to retry effects.

Governed effects use GAM recovery and their original command identities. An
ambiguous outcome remains unresolved: it must not be reported as proof of failure
or sent again blindly. A changed checkpoint fingerprint needs an explicit host
migration. Contract drift is handled by the core recovery rules rather than
invoking new adapter code with old arguments. See the
[core lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md)
and [AgentServer guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/AGENT_SERVER.md).
