defmodule SpectreLab.DependencySelectionContractTest do
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @spectre_requirement "~> 0.3.1"
  @ledger_requirement "~> 0.1.0"

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "spectre-lab-dependency-contract-#{System.unique_integer([:positive, :monotonic])}"
      )

    consumer = Path.join(workspace, "spectre_lab")
    spectre = Path.join(workspace, "spectre")
    ledger = Path.join(workspace, "spectre_ledger")

    File.mkdir_p!(consumer)
    File.mkdir_p!(spectre)
    File.mkdir_p!(ledger)
    File.cp!(Path.join(@root, "mix.exs"), Path.join(consumer, "mix.exs"))

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, consumer: consumer, ledger: ledger, spectre: spectre, workspace: workspace}
  end

  test "adjacent checkouts do not silently replace Hex requirements", context do
    assert File.dir?(context.spectre)
    assert File.dir?(context.ledger)

    deps = project_dependencies(context, [])

    assert dependency(deps, :spectre) == {:spectre, @spectre_requirement}
    assert dependency(deps, :spectre_ledger) == {:spectre_ledger, @ledger_requirement}
  end

  test "explicit environment variables select local path overrides", context do
    deps =
      project_dependencies(context, [
        {"SPECTRE_PATH", "../spectre"},
        {"SPECTRE_LEDGER_PATH", "../spectre_ledger"}
      ])

    assert {:spectre, spectre_opts} = dependency(deps, :spectre)
    assert spectre_opts == [path: context.spectre, override: true]

    assert {:spectre_ledger, ledger_opts} = dependency(deps, :spectre_ledger)
    assert ledger_opts == [path: context.ledger, override: true]
  end

  defp project_dependencies(context, dependency_env) do
    expression = """
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> :erlang.term_to_binary()
    |> Base.encode64()
    |> then(&IO.puts("SPECTRE_LAB_DEPS=" <> &1))
    """

    base_env = [
      {"MIX_BUILD_PATH", Path.join(context.workspace, "_build")},
      {"MIX_ENV", "test"},
      {"SPECTRE_PATH", nil},
      {"SPECTRE_LEDGER_PATH", nil}
    ]

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", expression],
        cd: context.consumer,
        env: base_env |> Map.new() |> Map.merge(Map.new(dependency_env)) |> Map.to_list(),
        stderr_to_stdout: true
      )

    assert status == 0, output

    encoded =
      output
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, "SPECTRE_LAB_DEPS=", parts: 2) do
          ["", value] -> value
          _other -> nil
        end
      end)

    assert is_binary(encoded), output

    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  defp dependency(dependencies, name) do
    Enum.find(dependencies, &(elem(&1, 0) == name))
  end
end
