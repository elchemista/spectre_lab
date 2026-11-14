defmodule Spectre.Lab do
  @moduledoc """
  AgentServer checkpoint inspection and verified offline evidence playback.

  In Spectre 0.4, install Lab alongside Ledger in a Stack and select it with
  `use Spectre.Server, tools: MyApp.AI`. The generated private
  `lab(ctx, {:inspect, :checkpoint}, opts)` helper resolves the current Server's
  trusted checkpoint in a worker and returns a bounded structural summary.
  Raw snapshots are not copied into the Server inbox. Codec validity is not a
  recovery identity check or permission to execute an action.

  `lab(ctx, {:inspect, :checkpoint, :operational}, opts)` returns the core's
  versioned metadata projection for that same checkpoint. The interaction form
  `lab(ctx, {:inspect, :interaction, interaction_id}, opts)` correlates retained
  checkpoint facts and explicitly reports incomplete historical coverage.
  Neither helper can select another Skill's checkpoint or read its GAM facts.

  Developer-facing `inspect/2` and `trace/2` delegate directly to the Server's
  authenticated diagnostic APIs. The actual calling process remains the caller
  evaluated by the Server; choosing a mode does not grant diagnostic authority.

  Lab adds no owner, scheduler, storage backend or live execution replay.
  Installation grants no authority; GAM remains responsible for the host's governed
  surface. See the [0.4 integration guide](SPECTRE_0_4.md) and the
  [Governed Act Model](https://spectre.guide/en/governed-act-model).

  The separate offline APIs consume Ledger's legacy checkpoint/receipt archives
  and provide a deterministic streaming fixture adapter. Those archive contracts
  are not AgentServer checkpoint files.
  """

  use Spectre.Stack.Installable,
    id: :spectre_lab,
    version: "0.1.0",
    contract: 1,
    spectre: "~> 0.4.0",
    requires: [{:package, :spectre_ledger, "~> 0.1.0"}],
    provides: [
      {:contract, {:spectre_lab, :checkpoint_playback, 1}},
      {:contract, {:spectre_lab, :boundary_receipt_playback, 1}},
      {:service, {:spectre_lab, :test_harness, 1}}
    ],
    metadata: %{
      lab_contract: 1,
      bundle_contract: 1,
      capability: :checkpoint_playback,
      receipt_capability: :boundary_receipt_playback,
      receipt_bundle: false,
      every_revision: false,
      deterministic_replay: false,
      live_io_default: :blocked
    }

  alias Spectre.Lab.Diff
  alias Spectre.Lab.Loader
  alias Spectre.Lab.Playback
  alias Spectre.Lab.ReceiptLoader
  alias Spectre.Lab.ReceiptPlayback
  alias Spectre.Ledger.Bundle
  alias Spectre.Ledger.ReceiptEntry
  alias Spectre.Receipt.Envelope

  @version "0.1.0"

  @impl Spectre.Stack.Installable
  def tools(config), do: Spectre.Lab.ServerTool.tools(config)

  @doc "Returns the Lab package version."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Inspects a running Server through its authorized operational diagnostic API.

  The root consumer may inspect its runtime; detailed access is decided by the
  Server, not by Lab or the supplied mode. Options are the closed options accepted
  by `Spectre.Server.inspect/2`. This call creates no worker or persistent owner.
  """
  @spec inspect(GenServer.server(), :operational, keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(server, mode, opts \\ [])

  def inspect(server, :operational, opts), do: Spectre.Server.inspect(server, opts)
  def inspect(_server, _mode, _opts), do: {:error, :invalid_lab_inspection_mode}

  @doc """
  Correlates recorded interaction facts through the Server's authorized trace API.

  The returned coverage describes available evidence and retained history; Lab
  does not synthesize missing events, reconstruct model reasoning or execute any
  operation. Options are those accepted by `Spectre.Server.trace/3`.
  """
  @spec trace(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace(server, interaction_id, opts \\ []),
    do: Spectre.Server.trace(server, interaction_id, opts)

  @doc """
  Loads a verified Ledger bundle for offline checkpoint playback.

  Only Ledger Bundle resource-limit options are accepted. Lab suppresses
  custom and global telemetry while loading so observers cannot turn an
  otherwise local playback into an implicit callback boundary.
  """
  @spec load(binary() | Bundle.t(), keyword()) :: {:ok, Playback.t()} | {:error, term()}
  defdelegate load(bundle, opts \\ []), to: Loader

  @doc "Builds an offline playback from one complete verified receipt chain."
  @spec load_receipts([ReceiptEntry.t()], [Envelope.t()]) ::
          {:ok, ReceiptPlayback.t()} | {:error, term()}
  defdelegate load_receipts(entries, envelopes), to: ReceiptLoader, as: :load

  @doc "Compares two verified checkpoint timelines."
  @spec diff(Playback.t(), Playback.t()) :: {:ok, Diff.Report.t()} | {:error, term()}
  defdelegate diff(left, right), to: Diff, as: :compare
end
