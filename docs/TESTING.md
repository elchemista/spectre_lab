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
