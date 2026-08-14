defmodule SpectreLab.MixGeneratorTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SpectreLab.Gen.Support
  alias Mix.Tasks.SpectreLab.Gen.Test, as: Generator

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "creates a deterministic, executable Lab test at the module path" do
    root = temporary_directory!("create")
    on_exit(fn -> File.rm_rf!(root) end)

    File.cd!(root, fn ->
      assert :ok = Generator.run(["MyApp.PlaybackTest"])

      destination = "test/my_app/playback_test.exs"
      assert File.regular?(destination)
      source = File.read!(destination)

      assert source =~ "defmodule MyApp.PlaybackTest"
      assert source =~ "use Spectre.Lab.TestCase, async: true"
      assert source =~ "assert_no_live_io"
      refute source =~ "ledger/bundle"
      assert {:ok, _ast} = Code.string_to_quoted(source)

      assert_generated_test_runs!(Path.expand(destination))

      first_source = source
      assert :ok = Generator.run(["MyApp.PlaybackTest", "--force"])
      assert File.read!(destination) == first_source
    end)
  end

  test "dry-run validates the plan without mutating the project" do
    root = temporary_directory!("dry-run")
    on_exit(fn -> File.rm_rf!(root) end)

    File.cd!(root, fn ->
      assert :ok =
               Generator.run([
                 "MyApp.Contract.PlaybackTest",
                 "--path",
                 "test/generated",
                 "--dry-run"
               ])

      refute File.exists?("test")

      assert_received {:mix_shell, :info,
                       ["would create test/generated/my_app/contract/playback_test.exs"]}
    end)
  end

  test "refuses every implicit overwrite and force replaces only regular files" do
    root = temporary_directory!("overwrite")
    on_exit(fn -> File.rm_rf!(root) end)

    File.cd!(root, fn ->
      assert :ok = Generator.run(["MyApp.PlaybackTest"])
      destination = "test/my_app/playback_test.exs"
      generated = File.read!(destination)

      assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
        Generator.run(["MyApp.PlaybackTest"])
      end

      assert File.read!(destination) == generated

      File.write!(destination, "user content")
      assert :ok = Generator.run(["MyApp.PlaybackTest", "--force"])
      assert File.read!(destination) == generated

      File.rm!(destination)
      File.mkdir_p!(destination)

      assert_raise Mix.Error, ~r/only replaces regular files/, fn ->
        Generator.run(["MyApp.PlaybackTest", "--force"])
      end
    end)
  end

  test "force never follows a hard link to an external inode" do
    root = temporary_directory!("hard-link")
    outside = temporary_directory!("hard-link-outside")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)

    outside_file = Path.join(outside, "owned.txt")
    File.write!(outside_file, "outside content")

    File.cd!(root, fn ->
      destination = "test/my_app/playback_test.exs"
      File.mkdir_p!(Path.dirname(destination))
      File.ln!(outside_file, destination)

      assert_raise Mix.Error, ~r/refuses files with multiple hard links/, fn ->
        Generator.run(["MyApp.PlaybackTest", "--force"])
      end

      assert File.read!(outside_file) == "outside content"
      assert File.read!(destination) == "outside content"
    end)
  end

  test "create refuses a target that appears after preflight" do
    root = temporary_directory!("create-race")
    on_exit(fn -> File.rm_rf!(root) end)

    File.cd!(root, fn ->
      plan = Support.plan_test!("MyApp.PlaybackTest", "test", false)
      File.mkdir_p!(Path.dirname(plan.destination))
      File.write!(plan.destination, "late user content")

      assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
        Support.write!(plan, false, false)
      end

      assert File.read!(plan.destination) == "late user content"
    end)
  end

  test "rejects invalid invocations before creating directories" do
    root = temporary_directory!("invalid")
    on_exit(fn -> File.rm_rf!(root) end)

    File.cd!(root, fn ->
      for argv <- [
            [],
            ["my_app.PlaybackTest"],
            ["Elixir.PlaybackTest"],
            ["MyApp.PlaybackTest", "Unexpected"],
            ["MyApp.PlaybackTest", "--unknown"]
          ] do
        assert_raise Mix.Error, fn -> Generator.run(argv) end
      end

      assert_raise Mix.Error, ~r/option --path may only be passed once/, fn ->
        Generator.run([
          "MyApp.PlaybackTest",
          "--path",
          "test/one",
          "--path",
          "test/two"
        ])
      end

      refute File.exists?("test")
    end)
  end

  test "rejects absolute, escaping, and symlinked destination parents" do
    root = temporary_directory!("containment")
    outside = temporary_directory!("outside")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.cd!(root, fn ->
      assert_raise Mix.Error, ~r/must stay inside the current project/, fn ->
        Generator.run(["MyApp.PlaybackTest", "--path", outside, "--dry-run"])
      end

      assert_raise Mix.Error, ~r/must stay inside the current project/, fn ->
        Generator.run(["MyApp.PlaybackTest", "--path", "../outside", "--dry-run"])
      end

      File.ln_s!(outside, "linked-tests")

      assert_raise Mix.Error, ~r/generator parent is a symlink/, fn ->
        Generator.run([
          "MyApp.PlaybackTest",
          "--path",
          "linked-tests/contracts",
          "--dry-run"
        ])
      end

      refute File.exists?(Path.join(outside, "contracts"))
    end)
  end

  defp assert_generated_test_runs!(path) do
    executable = System.find_executable("elixir") || flunk("Elixir executable is unavailable")

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    runner = """
    ExUnit.start(autorun: false)
    Code.require_file(System.fetch_env!("SPECTRE_LAB_GENERATED_TEST"))
    result = ExUnit.run()
    System.halt(if(result.failures == 0 and result.total == 1, do: 0, else: 1))
    """

    {output, status} =
      System.cmd(executable, code_paths ++ ["-e", runner],
        env: [
          {"ERL_FLAGS", "+S 2:2 +SDio 1 +SDcpu 1"},
          {"SPECTRE_LAB_GENERATED_TEST", path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/(1 test, 0 failures|Result: 1 passed)/
  end

  defp temporary_directory!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-lab-generator-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end
end
