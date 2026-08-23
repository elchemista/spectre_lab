# Security policy

## Reporting

Please report suspected vulnerabilities privately through the repository's
security advisory channel. Do not attach production bundles, checkpoints,
credentials, or customer data to a public issue.

## Bundle trust boundary

Ledger bundles and their checkpoints can contain sensitive application state.
Checksums and content digests prove integrity; they do not provide
confidentiality, authorization, provenance, or safe execution.

Lab 0.1.x accepts Bundle v1 only as a trusted/local artifact. Loading delegates
to `Spectre.Ledger.Bundle.verify/2`, which invokes the public Spectre Foundation
checkpoint verifier. Foundation decoding may load an existing BEAM module
named by a valid checkpoint. The bundle does not supply module code, and Lab
does not restore executable Runs, but the decode boundary is still unsuitable
for arbitrary untrusted input inside an application node.

For artifacts outside the trust boundary, reject them before Lab, verify their
provenance and authorization, and inspect them in a separately isolated node
with only an allowlisted code path. Apply encryption, access control, retention,
and deletion policy independently of bundle verification.

Bundle v1 verification is bounded and detects malformed envelopes, broken
entry chains, missing or extra objects, and digest mismatches. Those resource
and integrity checks do not change the trusted-artifact rule.

Receipt playbacks retain complete `Spectre.Receipt.Envelope` values, including
ordinary admitted input or model output that constitutional redaction does not
remove. They have no stable Lab serialization format and are not automatically
encrypted. Keep them in the same access-control, retention, and deletion
boundary as the Ledger backend, and capture only complete unpaginated chains.

## Test boundaries

`Spectre.Lab.IOFuse` is fail-closed only for functions explicitly passed to
`IOFuse.dispatch/2`. It does not intercept direct HTTP, socket, filesystem,
port, process, model-adapter, or other side-effecting calls. Tests must route
the relevant adapter boundary through the fuse or replace that adapter with a
test implementation.

Fault scripts operate only through `Spectre.Lab.Fault.CheckpointStore` and
`Spectre.Lab.Fault.ReceiptSink`, which wrap public Spectre contracts. The
controller stores scripted reasons supplied by the test; do not place
production secrets in a script. Snapshots expose only counters and remaining
action counts, never receipt payloads or checkpoint bytes.

Sandboxes and controllers are caller-owned and unregistered. Hosts remain
responsible for supervision, process authorization, and cleanup of any resource
started outside a Lab sandbox.

Virtual stream scripts reside in the caller and Spectre session processes for
the duration of a test. Do not put production prompts, credentials, provider
metadata, or customer responses in fixtures. Optional observer messages never
contain response deltas and reduce cancellation reasons to a stable class, but
the public Stream events intentionally contain the scripted response text.

## Diagnostics and dependencies

Lab Doctor is read-only and does not open a Ledger backend. Mix tasks read only
the explicitly supplied bundle path, cap input at 64 MiB, and avoid echoing
bundle contents or paths in stable failure messages.

Lab has no PostgreSQL runtime dependency and never starts or configures an Ecto
Repo. PostgreSQL credentials, migrations, and storage remain outside Lab's
scope.

## Supported versions

Security fixes are provided for the latest released Spectre Lab 0.1.x version
while it remains compatible with Spectre 0.3.3 and Spectre Ledger 0.1.x.
