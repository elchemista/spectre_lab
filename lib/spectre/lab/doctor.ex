defmodule Spectre.Lab.Doctor do
  @moduledoc """
  Read-only diagnostics for the Spectre Lab offline boundary.

  Doctor composes the public Spectre Doctor and Stack conformance contracts.
  It verifies the Ledger bundle contract without opening a Ledger backend or
  starting runtime resources. When `:bundle` is supplied, its binary contents
  are passed directly to `Spectre.Lab.load/2`; file access belongs to callers
  such as the Mix tasks.
  """

  alias Spectre.Doctor, as: CoreDoctor
  alias Spectre.Lab
  alias Spectre.Lab.Doctor.Report
  alias Spectre.Lab.Playback
  alias Spectre.Ledger
  alias Spectre.Ledger.Bundle
  alias Spectre.Stack.Conformance, as: StackConformance
  alias Spectre.Stack.Installable

  @contract_version 1
  @options [:bundle, :core]
  @bundle_manifest %{
    "capture" => "persisted_checkpoints",
    "completeness" => "checkpoint_playback",
    "every_revision" => false,
    "deterministic_replay_claim" => false
  }

  @doc "Runs composed core, version, Stack, and optional bundle diagnostics."
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(opts \\ []) do
    with :ok <- options(opts),
         {:ok, core} <- core_report(Keyword.get(opts, :core, [])) do
      checks = [
        safe("lab.versions", &versions_check/0),
        safe("lab.stack", &stack_check/0),
        safe("lab.bundle_contract", &bundle_contract_check/0),
        safe("lab.bundle_artifact", fn -> bundle_check(Keyword.get(opts, :bundle)) end)
      ]

      {:ok, report(core, checks)}
    end
  end

  @doc "Returns the stable Lab Doctor report contract version."
  @spec contract_version() :: 1
  def contract_version, do: @contract_version

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_lab_doctor_options}

        Enum.any?(keys, &(&1 not in @options)) ->
          {:error, :unknown_lab_doctor_options}

        not core_options?(Keyword.get(opts, :core, [])) ->
          {:error, :invalid_lab_doctor_core_options}

        not bundle?(Keyword.get(opts, :bundle)) ->
          {:error, :invalid_lab_doctor_bundle}

        true ->
          :ok
      end
    else
      {:error, :invalid_lab_doctor_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_lab_doctor_options}

  defp core_options?(opts), do: is_list(opts) and Keyword.keyword?(opts)
  defp bundle?(bundle), do: is_nil(bundle) or is_binary(bundle)

  defp core_report(opts) do
    case CoreDoctor.run(opts) do
      {:ok, report} -> {:ok, report}
      {:error, _reason} -> {:error, :invalid_lab_doctor_core_options}
    end
  rescue
    _exception -> {:error, :lab_core_doctor_exception}
  catch
    _kind, _reason -> {:error, :lab_core_doctor_failure}
  end

  defp versions_check do
    with {:ok, lab_package} <- Installable.verify(Lab),
         {:ok, ledger_package} <- Installable.verify(Ledger),
         true <- lab_package.version == Lab.version(),
         true <- ledger_package.version == Ledger.version(),
         true <- version_matches?(Spectre.version(), "~> 0.3.2"),
         true <- version_matches?(Ledger.version(), "~> 0.1.0"),
         true <- version_matches?(Lab.version(), "~> 0.1.0"),
         true <- application_version_matches?(:spectre_lab, Lab.version()) do
      check(:ok, "lab.versions", :lab_versions_compatible, %{
        spectre_version: Spectre.version(),
        ledger_version: Ledger.version(),
        lab_version: Lab.version()
      })
    else
      _invalid -> check(:error, "lab.versions", :lab_versions_incompatible)
    end
  end

  defp version_matches?(version, requirement) do
    match?({:ok, _parsed}, Version.parse(version)) and Version.match?(version, requirement)
  end

  defp application_version_matches?(application, expected) do
    case Application.spec(application, :vsn) do
      nil -> true
      version when is_binary(version) -> version == expected
      version when is_list(version) -> List.to_string(version) == expected
      _invalid -> false
    end
  end

  defp stack_check do
    case StackConformance.run([Ledger, Lab]) do
      {:ok, result} ->
        check(:ok, "lab.stack", :lab_stack_compatible, %{
          contract_version: result.contract_version,
          package_count: result.package_count,
          digest: result.stack_digest
        })

      {:error, _reason} ->
        check(:error, "lab.stack", :lab_stack_incompatible)
    end
  end

  defp bundle_contract_check do
    if Bundle.manifest() == @bundle_manifest do
      check(:ok, "lab.bundle_contract", :ledger_bundle_contract_valid, %{
        bundle_version: Bundle.version(),
        capture: "persisted_checkpoints",
        capability: "checkpoint_playback",
        every_revision: false,
        deterministic_replay: false
      })
    else
      check(:error, "lab.bundle_contract", :ledger_bundle_contract_invalid)
    end
  end

  defp bundle_check(nil),
    do: check(:skipped, "lab.bundle_artifact", :lab_bundle_not_requested)

  defp bundle_check(bundle) do
    case Lab.load(bundle) do
      {:ok, %Playback{} = playback} ->
        check(:ok, "lab.bundle_artifact", :lab_bundle_verified, %{
          entry_count: playback.verification.entry_count,
          object_count: playback.verification.object_count,
          head_revision: playback.verification.head_revision,
          revision_gap_count: length(playback.completeness.revision_gaps)
        })

      {:error, reason} ->
        check(:error, "lab.bundle_artifact", :lab_bundle_invalid, %{
          reason_class: reason_class(reason)
        })
    end
  end

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_class(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: tuple_reason_class(reason)

  defp reason_class(_reason), do: "invalid"

  defp tuple_reason_class(reason) do
    case elem(reason, 0) do
      class when is_atom(class) -> Atom.to_string(class)
      _value -> "invalid"
    end
  end

  defp check(status, id, code, details \\ %{}) do
    summary = code |> Atom.to_string() |> String.replace("_", " ")
    %{id: id, status: status, code: code, summary: summary, details: details}
  end

  defp safe(id, callback) do
    case callback.() do
      %{id: ^id, status: status, code: code, summary: summary, details: details} = result
      when status in [:ok, :warning, :error, :skipped] and is_atom(code) and
             is_binary(summary) and is_map(details) ->
        result

      _invalid ->
        check(:error, id, :lab_doctor_check_invalid)
    end
  rescue
    _exception -> check(:error, id, :lab_doctor_check_exception)
  catch
    _kind, _reason -> check(:error, id, :lab_doctor_check_failure)
  end

  defp report(core, checks) do
    local_counts = Enum.frequencies_by(checks, & &1.status)
    summary = merge_summary(core.summary, local_counts, length(checks))

    status =
      cond do
        summary.errors > 0 -> :error
        summary.warnings > 0 -> :warning
        true -> :ok
      end

    %Report{
      contract_version: @contract_version,
      lab_version: Lab.version(),
      ledger_version: Ledger.version(),
      spectre_version: Spectre.version(),
      status: status,
      core: core,
      checks: checks,
      summary: summary
    }
  end

  defp merge_summary(core, local, local_total) do
    %{
      total: core.total + local_total,
      passed: core.passed + (local[:ok] || 0),
      warnings: core.warnings + (local[:warning] || 0),
      errors: core.errors + (local[:error] || 0),
      skipped: core.skipped + (local[:skipped] || 0)
    }
  end
end
