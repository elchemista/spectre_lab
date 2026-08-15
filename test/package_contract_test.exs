defmodule SpectreLab.PackageContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Conformance, as: StackConformance
  alias Spectre.Stack.Installable

  test "package manifest composes Ledger against Spectre 0.3.2" do
    assert {:ok, package} = Installable.verify(Spectre.Lab)
    assert package.id == :spectre_lab
    assert package.version == "0.1.0"
    assert package.spectre == "~> 0.3.2"
    assert package.requires == [{:package, :spectre_ledger, "~> 0.1.0"}]
    assert package.agent_extensions == []
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []

    assert {:contract, {:spectre_lab, :checkpoint_playback, 1}} in package.provides
    assert {:service, {:spectre_lab, :test_harness, 1}} in package.provides

    assert package.metadata == %{
             capability: :checkpoint_playback,
             bundle_contract: 1,
             every_revision: false,
             deterministic_replay: false,
             lab_contract: 1,
             live_io_default: :blocked
           }

    assert {:ok, report} = StackConformance.run([Spectre.Ledger, Spectre.Lab])
    assert report.core_version == "0.3.2"
    assert report.package_count == 2
    assert Enum.map(report.packages, & &1.id) == [:spectre_ledger, :spectre_lab]
  end

  test "release versions and runtime applications exclude PostgreSQL" do
    assert Spectre.version() == "0.3.2"
    assert Spectre.Ledger.version() == "0.1.0"
    assert Spectre.Lab.version() == "0.1.0"

    assert {:ok, applications} = :application.get_key(:spectre_lab, :applications)
    assert :spectre in applications
    assert :spectre_ledger in applications
    assert :jason in applications
    refute :ecto in applications
    refute :ecto_sql in applications
    refute :postgrex in applications

    dependencies = Mix.Project.config()[:deps]
    names = Enum.map(dependencies, &elem(&1, 0))
    refute :ecto in names
    refute :ecto_sql in names
    refute :postgrex in names
  end

  test "production playback code stays outside Canonical internals" do
    sources =
      Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__)) ++
        Path.wildcard(Path.expand("support/**/*.{ex,exs}", __DIR__))

    assert sources != []

    canonical_boundary = Enum.join(["Spectre", "Instance", "Canonical"], ".")
    private_prepare = Enum.join(["Spectre", "Ledger", "CheckpointStore", "prepare"], ".")

    for source <- sources do
      contents = File.read!(source)

      refute contents =~ canonical_boundary,
             "#{Path.relative_to_cwd(source)} crosses the Canonical-internals boundary"

      refute contents =~ private_prepare,
             "#{Path.relative_to_cwd(source)} crosses the Ledger-internals boundary"
    end
  end
end
