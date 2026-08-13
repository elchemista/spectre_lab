defmodule SpectreLab.MixTasksDoctorTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SpectreLab.Bundle.Verify, as: BundleVerifyTask
  alias Mix.Tasks.SpectreLab.BundleInput
  alias Mix.Tasks.SpectreLab.Doctor, as: DoctorTask
  alias SpectreLab.PublicFixture

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-lab-bundle-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, bundle!(), [:binary])

    on_exit(fn ->
      File.rm(path)
      Mix.shell(previous_shell)
      Mix.Task.reenable("spectre_lab.doctor")
      Mix.Task.reenable("spectre_lab.bundle.verify")
    end)

    {:ok, path: path}
  end

  test "doctor emits a JSON-safe report for a verified file", %{path: path} do
    reenable("spectre_lab.doctor")
    assert :ok = DoctorTask.run(["--bundle", path, "--format", "json"])

    assert_receive {:mix_shell, :info, [output]}
    assert {:ok, report} = Jason.decode(output)
    assert report["status"] == "ok"
    assert report["lab_version"] == "0.1.0"

    artifact = Enum.find(report["checks"], &(&1["id"] == "lab.bundle_artifact"))
    assert artifact["code"] == "lab_bundle_verified"
  end

  test "bundle.verify emits a focused data-only verification", %{path: path} do
    reenable("spectre_lab.bundle.verify")

    assert :ok =
             BundleVerifyTask.run([path, "--format", "json"])

    assert_receive {:mix_shell, :info, [output]}
    assert {:ok, result} = Jason.decode(output)
    assert result["status"] == "ok"
    assert result["capture"] == "persisted_checkpoints"
    assert result["entry_count"] == 1
    assert result["head_revision"] == 0
    refute result["every_revision"]
    refute result["deterministic_replay"]
  end

  test "tasks support their default text formats", %{path: path} do
    reenable("spectre_lab.doctor")
    assert :ok = DoctorTask.run([])
    assert_receive {:mix_shell, :info, [doctor_output]}
    assert doctor_output =~ "Spectre Lab doctor 0.1.0: ok"
    assert doctor_output =~ "lab_bundle_not_requested"

    reenable("spectre_lab.bundle.verify")
    assert :ok = BundleVerifyTask.run([path])
    assert_receive {:mix_shell, :info, [bundle_output]}
    assert bundle_output =~ "Spectre Lab bundle: ok"
    assert bundle_output =~ "Persisted checkpoints: 1"
  end

  test "tasks return stable errors and never echo a corrupt path or contents", %{path: path} do
    private = "private bundle contents #{System.unique_integer([:positive])}"
    File.write!(path, private)

    reenable("spectre_lab.bundle.verify")

    error =
      assert_raise Mix.Error, ~r/^\[spectre_lab_bundle_verify_invalid\]/, fn ->
        BundleVerifyTask.run([path])
      end

    refute Exception.message(error) =~ path
    refute Exception.message(error) =~ private

    reenable("spectre_lab.doctor")

    error =
      assert_raise Mix.Error, ~r/^\[spectre_lab_doctor_failed\]/, fn ->
        DoctorTask.run(["--bundle", path])
      end

    refute Exception.message(error) =~ path
    refute Exception.message(error) =~ private
  end

  test "tasks reject unknown, duplicate, missing, and unreadable inputs" do
    reenable("spectre_lab.doctor")

    assert_raise Mix.Error, ~r/spectre_lab_doctor_invalid_arguments/, fn ->
      DoctorTask.run(["--strict", "--strict"])
    end

    reenable("spectre_lab.doctor")

    assert_raise Mix.Error, ~r/spectre_lab_doctor_invalid_arguments/, fn ->
      DoctorTask.run(["--unknown"])
    end

    reenable("spectre_lab.bundle.verify")

    assert_raise Mix.Error, ~r/spectre_lab_bundle_verify_invalid_arguments/, fn ->
      BundleVerifyTask.run([])
    end

    reenable("spectre_lab.bundle.verify")

    assert_raise Mix.Error, ~r/spectre_lab_bundle_verify_read/, fn ->
      BundleVerifyTask.run(["/path/that/does/not/exist"])
    end

    reenable("spectre_lab.doctor")

    assert_raise Mix.Error, ~r/spectre_lab_doctor_bundle_read/, fn ->
      DoctorTask.run(["--bundle", "/path/that/does/not/exist"])
    end

    reenable("spectre_lab.doctor")

    assert_raise Mix.Error, ~r/spectre_lab_doctor_invalid_format/, fn ->
      DoctorTask.run(["--format", "yaml"])
    end

    reenable("spectre_lab.bundle.verify")

    assert_raise Mix.Error, ~r/spectre_lab_bundle_verify_invalid_format/, fn ->
      BundleVerifyTask.run(["unused", "--format", "yaml"])
    end

    reenable("spectre_lab.bundle.verify")

    assert_raise Mix.Error, ~r/spectre_lab_bundle_verify_invalid_arguments/, fn ->
      BundleVerifyTask.run(["", "--format=json", "--format=text"])
    end
  end

  test "the task reader closes files and enforces its explicit bound", %{path: path} do
    assert {:error, :invalid_path} = BundleInput.read(nil)
    assert {:error, :invalid_path} = BundleInput.read("")
    assert BundleInput.unique_switches?(["--strict"])
    refute BundleInput.unique_switches?(["--strict", "--no-strict"])

    File.write!(path, "")
    assert {:ok, ""} = BundleInput.read(path)

    {:ok, device} = File.open(path, [:write, :binary])
    {:ok, _position} = :file.position(device, 64 * 1_024 * 1_024)
    :ok = IO.binwrite(device, <<0>>)
    :ok = File.close(device)

    assert {:error, :too_large} = BundleInput.read(path)

    reenable("spectre_lab.doctor")

    assert_raise Mix.Error, ~r/spectre_lab_doctor_bundle_too_large/, fn ->
      DoctorTask.run(["--bundle", path])
    end

    reenable("spectre_lab.bundle.verify")

    assert_raise Mix.Error, ~r/spectre_lab_bundle_verify_too_large/, fn ->
      BundleVerifyTask.run([path])
    end
  end

  defp reenable(task), do: Mix.Task.reenable(task)

  defp bundle!, do: PublicFixture.static_bundle!()
end
