defmodule SpectreLab.DoctorTest do
  use ExUnit.Case, async: false

  alias Spectre.Lab.Doctor
  alias Spectre.Lab.Doctor.Report
  alias Spectre.Ledger.Backend.Memory
  alias Spectre.Ledger.Backend.Postgres
  alias SpectreLab.PublicFixture

  defmodule TrapCheckpointStore do
    @behaviour Spectre.Instance.CheckpointStore

    @impl true
    def load(_ref, opts) do
      send(Keyword.fetch!(opts, :test_pid), :checkpoint_load_called)
      raise "Doctor must not call load"
    end

    @impl true
    def compare_and_swap(_ref, _checkpoint, _expected, _revision, opts) do
      send(Keyword.fetch!(opts, :test_pid), :checkpoint_cas_called)
      raise "Doctor must not call compare_and_swap"
    end
  end

  test "composes public core and Stack checks without invoking checkpoint or Ledger backends" do
    bundle = bundle!()
    targets = traced_backend_functions()

    Enum.each(targets, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call])

    try do
      assert {:ok, report} =
               Doctor.run(
                 core: [checkpoint_store: {TrapCheckpointStore, test_pid: self()}],
                 bundle: bundle
               )

      assert report.status == :warning
      assert report.spectre_version == "0.3.3"
      assert report.ledger_version == "0.1.0"
      assert report.lab_version == "0.1.0"

      assert %{status: :warning, code: :checkpoint_erasure_unsupported} =
               Enum.find(report.core.checks, &(&1.id == "privacy.checkpoint_erasure"))

      assert %{status: :ok, code: :lab_stack_compatible} = check(report, "lab.stack")

      assert %{status: :ok, code: :ledger_receipt_contract_valid} =
               check(report, "lab.receipt_contract")

      assert %{status: :ok, code: :lab_bundle_verified, details: details} =
               check(report, "lab.bundle_artifact")

      assert details.entry_count == 1
      assert details.head_revision == 0
      refute_received :checkpoint_load_called
      refute_received :checkpoint_cas_called

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {:trace, _pid, :call, {module, _function, _arguments}} ->
                 module in [Memory, Postgres]

               _message ->
                 false
             end)
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(targets, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end

  test "reports a corrupt bundle without exposing its contents or raw failure" do
    private = "private customer payload #{System.unique_integer([:positive])}"

    assert {:ok, report} = Doctor.run(bundle: private)
    assert report.status == :error

    assert %{status: :error, code: :lab_bundle_invalid, details: details} =
             check(report, "lab.bundle_artifact")

    assert is_binary(details.reason_class)
    refute inspect(report) =~ private
    refute Report.format(report, :text) =~ private
    refute Report.format(report, :json) =~ private
    refute Report.acceptable?(report)
  end

  test "returns a stable closed option contract" do
    assert {:error, :invalid_lab_doctor_options} = Doctor.run(:invalid)
    assert {:error, :invalid_lab_doctor_options} = Doctor.run([:not_a_keyword])
    assert {:error, :duplicate_lab_doctor_options} = Doctor.run(bundle: "a", bundle: "b")
    assert {:error, :unknown_lab_doctor_options} = Doctor.run(backend: :memory)
    assert {:error, :invalid_lab_doctor_bundle} = Doctor.run(bundle: %{secret: true})
    assert {:error, :invalid_lab_doctor_core_options} = Doctor.run(core: :invalid)

    assert {:error, :invalid_lab_doctor_core_options} =
             Doctor.run(core: [unknown_core_option: true])
  end

  test "formats stable text and JSON reports and applies strict acceptance" do
    assert Doctor.contract_version() == 1
    assert {:ok, report} = Doctor.run()
    assert Report.acceptable?(report)
    assert Report.acceptable?(report, strict: true)

    assert Report.format(report, :text) =~ "Spectre Lab doctor 0.1.0: ok"
    assert {:ok, json} = report |> Report.format(:json) |> Jason.decode()
    assert json["contract_version"] == 1
    assert json["core"]["spectre_version"] == "0.3.3"
    assert json["summary"]["errors"] == 0

    warning = %{report | summary: %{report.summary | warnings: 1}}
    assert Report.acceptable?(warning)
    refute Report.acceptable?(warning, strict: true)
  end

  test "text output includes the core checks that contribute to its summary" do
    assert {:ok, report} = Doctor.run(core: [packages: []])
    assert report.status == :error
    assert report.summary.errors > 0

    text = Report.format(report, :text)
    assert text =~ "packages.compatibility"
    assert text =~ "packages_empty"
  end

  test "report conversion recursively permits data and redacts runtime values" do
    assert {:ok, report} = Doctor.run()

    custom_check = %{
      id: "lab.redaction",
      status: :warning,
      code: :redaction_observed,
      summary: "redaction observed",
      details: %{
        "list" => [1, self()],
        {1, 2} => %URI{scheme: "private"},
        atom: :portable
      }
    }

    mapped = Report.to_map(%{report | checks: [custom_check]})
    [check] = mapped.checks
    assert check.details["atom"] == "portable"
    assert check.details["list"] == [1, "<redacted>"]
    assert check.details["redacted_key"] == "<redacted>"
    assert Report.format(report) =~ "Spectre Lab doctor"
  end

  defp check(report, id), do: Enum.find(report.checks, &(&1.id == id))

  defp traced_backend_functions do
    modules = [Memory, Postgres]
    Enum.each(modules, &Code.ensure_loaded?/1)

    for module <- modules,
        {function, arity} <- module.__info__(:functions),
        function in [:load, :compare_and_swap, :head, :entries, :objects, :put_stream],
        do: {module, function, arity}
  end

  defp bundle!, do: PublicFixture.static_bundle!()
end
