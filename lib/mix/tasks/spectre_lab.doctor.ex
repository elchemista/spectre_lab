defmodule Mix.Tasks.SpectreLab.Doctor do
  @moduledoc "Runs read-only Spectre Lab diagnostics in text or JSON form."

  use Mix.Task

  alias Mix.Tasks.SpectreLab.BundleInput
  alias Spectre.Lab.Doctor
  alias Spectre.Lab.Doctor.Report

  @shortdoc "Check Spectre Lab contracts and an optional bundle"
  @switches [bundle: :string, format: :string, strict: :boolean]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    validate_arguments!(argv, args, invalid)

    format = format!(opts[:format] || "text")
    doctor_opts = doctor_options!(opts[:bundle])

    report =
      case Doctor.run(doctor_opts) do
        {:ok, report} -> report
        {:error, _reason} -> fail("invalid_options", "invalid doctor options")
      end

    Mix.shell().info(Report.format(report, format))
    enforce!(report, opts[:strict] == true)
    :ok
  end

  defp validate_arguments!(argv, args, invalid) do
    if args != [] or invalid != [] or not BundleInput.unique_switches?(argv),
      do: fail("invalid_arguments", "invalid arguments")
  end

  defp doctor_options!(nil), do: []

  defp doctor_options!(path) do
    case BundleInput.read(path) do
      {:ok, bundle} -> [bundle: bundle]
      {:error, :too_large} -> fail("bundle_too_large", "bundle exceeds 64 MiB")
      {:error, _reason} -> fail("bundle_read", "bundle is unavailable")
    end
  end

  defp format!("text"), do: :text
  defp format!("json"), do: :json
  defp format!(_format), do: fail("invalid_format", "expected --format text or json")

  defp enforce!(report, strict?) do
    unless Report.acceptable?(report, strict: strict?) do
      code = if report.summary.errors == 0 and strict?, do: "strict_failed", else: "failed"
      fail(code, "checks did not pass")
    end
  end

  @spec fail(String.t(), String.t()) :: no_return()
  defp fail(code, message), do: Mix.raise("[spectre_lab_doctor_#{code}] #{message}")
end
