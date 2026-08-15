defmodule Spectre.Lab do
  @moduledoc """
  Verified offline checkpoint playback and testing tools for Spectre 0.3.2.

  Lab consumes the bundle format owned by Spectre Ledger. It does not add an
  owner, scheduler, storage backend, or live execution replay to Spectre.
  """

  use Spectre.Stack.Installable,
    id: :spectre_lab,
    version: "0.1.0",
    contract: 1,
    spectre: "~> 0.3.2",
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

  @doc "Returns the Lab package version."
  @spec version() :: String.t()
  def version, do: @version

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
