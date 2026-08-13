defmodule Mix.Tasks.SpectreLab.Bundle.Verify do
  @moduledoc "Verifies one bounded Ledger bundle for offline Lab playback."

  use Mix.Task

  alias Mix.Tasks.SpectreLab.BundleInput
  alias Spectre.Lab
  alias Spectre.Lab.Playback

  @shortdoc "Verify a Ledger checkpoint bundle"
  @switches [format: :string]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    path = path!(argv, args, invalid)
    format = format!(opts[:format] || "text")
    bundle = bundle!(path)

    playback =
      case Lab.load(bundle) do
        {:ok, %Playback{} = playback} -> playback
        {:error, _reason} -> fail("invalid", "bundle verification failed")
      end

    Mix.shell().info(format(playback, format))
    :ok
  end

  defp path!(argv, [path], []) do
    if BundleInput.unique_switches?(argv) and path != "",
      do: path,
      else: fail("invalid_arguments", "expected exactly one bundle path")
  end

  defp path!(_argv, _args, _invalid),
    do: fail("invalid_arguments", "expected exactly one bundle path")

  defp bundle!(path) do
    case BundleInput.read(path) do
      {:ok, bundle} -> bundle
      {:error, :too_large} -> fail("too_large", "bundle exceeds 64 MiB")
      {:error, _reason} -> fail("read", "bundle is unavailable")
    end
  end

  defp format!("text"), do: :text
  defp format!("json"), do: :json
  defp format!(_format), do: fail("invalid_format", "expected --format text or json")

  defp format(%Playback{} = playback, :json) do
    playback
    |> result()
    |> Jason.encode!(pretty: true)
  end

  defp format(%Playback{} = playback, :text) do
    data = result(playback)

    """
    Spectre Lab bundle: ok
    Bundle version: #{data.bundle_version}
    Capability: #{data.capability}
    Persisted checkpoints: #{data.entry_count}
    Head revision: #{data.head_revision}
    Revision gaps: #{data.revision_gap_count}
    """
    |> String.trim()
  end

  defp result(%Playback{} = playback) do
    %{
      status: "ok",
      bundle_version: playback.verification.bundle_version,
      capability: "checkpoint_playback",
      capture: "persisted_checkpoints",
      every_revision: false,
      deterministic_replay: false,
      entry_count: playback.verification.entry_count,
      object_count: playback.verification.object_count,
      head_revision: playback.verification.head_revision,
      revision_gap_count: length(playback.completeness.revision_gaps)
    }
  end

  @spec fail(String.t(), String.t()) :: no_return()
  defp fail(code, message), do: Mix.raise("[spectre_lab_bundle_verify_#{code}] #{message}")
end
