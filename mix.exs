defmodule SpectreLab.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elchemista/spectre_lab"

  def project do
    [
      app: :spectre_lab,
      name: "Spectre Lab",
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 90]],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      description: "Verified offline evidence playback and testing tools for Spectre.",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      spectre_dep(),
      ledger_dep(),
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp spectre_dep do
    dependency(:spectre, "SPECTRE_PATH", "~> 0.3.3")
  end

  defp ledger_dep do
    case System.get_env("SPECTRE_LEDGER_PATH") do
      path when is_binary(path) and path != "" ->
        {:spectre_ledger, [path: Path.expand(path, __DIR__), override: true]}

      _unset ->
        # Ledger 0.1.0 is intentionally GitHub-only until its owner publishes
        # it. Keeping this source explicit makes a clean Lab checkout usable
        # without pretending that a Hex package already exists.
        {:spectre_ledger,
         [
           github: "elchemista/spectre_ledger",
           ref: "404858a4e1e91716a13219e87bf5308f3efd2395",
           override: true
         ]}
    end
  end

  defp dependency(name, env, requirement) do
    case System.get_env(env) do
      path when is_binary(path) and path != "" ->
        {name, [path: Path.expand(path, __DIR__), override: true]}

      _unset ->
        {name, requirement}
    end
  end

  defp package do
    [
      name: "spectre_lab",
      maintainers: ["elchemista"],
      files: ~w(lib priv docs mix.exs .formatter.exs README.md CHANGELOG.md SECURITY.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "#{@source_url}/blob/main/README.md",
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: @version,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "docs/ARCHITECTURE.md",
        "docs/PUBLIC_API.md",
        "docs/TESTING.md"
      ]
    ]
  end
end
