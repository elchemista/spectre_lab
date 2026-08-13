defmodule Mix.Tasks.SpectreLab.Gen.Test do
  @moduledoc """
  Generates a Spectre Lab test case.

      mix spectre_lab.gen.test MyApp.PlaybackTest
      mix spectre_lab.gen.test MyApp.PlaybackTest --path test/contract

  The module alias determines the file below the selected directory. For
  example, `MyApp.PlaybackTest` is written to
  `test/my_app/playback_test.exs` by default.

  The generator validates the complete plan before writing. It never follows
  a symlinked parent or overwrites a file unless `--force` is explicit.

  ## Options

    * `--path` - relative destination directory, default `test`;
    * `--dry-run` - validate and print the plan without changing files;
    * `--force` - replace an existing regular file.
  """

  use Mix.Task

  alias Mix.Tasks.SpectreLab.Gen.Support

  @shortdoc "Generate an offline Spectre Lab test"
  @switches [
    path: [:string, :keep],
    dry_run: [:boolean, :keep],
    force: [:boolean, :keep]
  ]
  @usage "expected: mix spectre_lab.gen.test MyApp.PlaybackTest [--path test] [--dry-run] [--force]"

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or length(args) != 1, do: Mix.raise(@usage)

    :ok = Support.reject_duplicate_options!(opts)
    module = args |> List.first() |> Support.module_name!()
    directory = Keyword.get(opts, :path, "test")
    force? = Keyword.get(opts, :force, false)
    dry_run? = Keyword.get(opts, :dry_run, false)

    module
    |> Support.plan_test!(directory, force?)
    |> Support.write!(dry_run?, force?)
  end
end
