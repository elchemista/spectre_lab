defmodule SpectreLab.HexReleaseContractTest do
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @version "0.1.0"
  @spectre_requirement "~> 0.3.1"
  @ledger_requirement "~> 0.1.0"
  @documentation_files ["README.md", "CHANGELOG.md", "SECURITY.md"] ++
                         Path.wildcard("docs/*.md", match_dot: true)

  test "Mix and Hex metadata describe the 0.1.0 release" do
    config = Mix.Project.config()
    package = Keyword.fetch!(config, :package)

    assert config[:version] == @version
    assert config[:homepage_url] == "https://github.com/elchemista/spectre_lab"

    assert config[:description] ==
             "Verified offline checkpoint playback and testing tools for Spectre."

    assert package[:name] == "spectre_lab"
    assert package[:maintainers] == ["elchemista"]
    assert package[:licenses] == ["Apache-2.0"]

    assert package[:links] == %{
             "Documentation" => "https://hexdocs.pm/spectre_lab/#{@version}",
             "GitHub" => "https://github.com/elchemista/spectre_lab",
             "Changelog" =>
               "https://github.com/elchemista/spectre_lab/blob/#{@version}/CHANGELOG.md"
           }

    assert {:ex_doc, "~> 0.40.3", ex_doc_opts} =
             Enum.find(config[:deps], &match?({:ex_doc, _, _}, &1))

    assert ex_doc_opts[:only] == :dev
    assert ex_doc_opts[:runtime] == false

    dependency_names = Enum.map(config[:deps], &elem(&1, 0))
    refute :ecto in dependency_names
    refute :ecto_sql in dependency_names
    refute :postgrex in dependency_names
  end

  test "all Markdown guides are in ExDoc and every local link resolves" do
    extras = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:extras)

    assert MapSet.subset?(
             MapSet.new(Path.wildcard("docs/*.md", match_dot: true)),
             MapSet.new(extras)
           )

    assert "docs/PUBLIC_API.md" in extras
    assert "docs/TESTING.md" in extras

    for relative_file <- @documentation_files,
        target <- markdown_targets(relative_file),
        local_target?(target) do
      assert_local_target!(relative_file, target)
    end
  end

  @tag timeout: 30_000
  test "Hex unpack contains the offline contract and remote release requirements" do
    unpack_dir =
      Path.join(
        System.tmp_dir!(),
        "spectre-lab-hex-#{System.unique_integer([:positive, :monotonic])}"
      )

    build_dir = Path.join(unpack_dir, ".mix-build")
    on_exit(fn -> File.rm_rf!(unpack_dir) end)

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["hex.build", "--unpack", "--output", unpack_dir],
        cd: @root,
        env: [
          {"SPECTRE_PATH", nil},
          {"SPECTRE_LEDGER_PATH", nil},
          {"MIX_ENV", "prod"},
          {"MIX_BUILD_PATH", build_dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Building spectre_lab #{@version}"

    metadata_path = Path.join(unpack_dir, "hex_metadata.config")
    assert {:ok, metadata} = :file.consult(String.to_charlist(metadata_path))
    assert metadata_value(metadata, "name") == "spectre_lab"
    assert metadata_value(metadata, "version") == @version

    requirements =
      metadata
      |> metadata_value("requirements")
      |> Map.new(fn requirement ->
        {metadata_value(requirement, "name"),
         %{
           requirement: metadata_value(requirement, "requirement"),
           optional: metadata_value(requirement, "optional")
         }}
      end)

    assert requirements == %{
             "jason" => %{requirement: "~> 1.4", optional: nil},
             "spectre" => %{requirement: @spectre_requirement, optional: nil},
             "spectre_ledger" => %{requirement: @ledger_requirement, optional: nil}
           }

    files = metadata_value(metadata, "files")
    assert "docs/PUBLIC_API.md" in files
    assert "docs/TESTING.md" in files
    assert "lib/spectre/lab/playback.ex" in files
    assert "lib/spectre/lab/test_case.ex" in files
    assert "priv/templates/spectre_lab.gen.test/playback_test.exs.eex" in files
    refute Enum.any?(files, &String.starts_with?(&1, "test"))
    refute "mix.lock" in files
  end

  test "development path overrides retain the published requirements" do
    source = File.read!(Path.join(@root, "mix.exs"))
    assert source =~ @spectre_requirement
    assert source =~ @ledger_requirement

    assert_dependency(:spectre, @spectre_requirement)
    assert_dependency(:spectre_ledger, @ledger_requirement)
  end

  defp assert_dependency(name, requirement) do
    case Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == name)) do
      {^name, ^requirement} ->
        :ok

      {^name, opts} when is_list(opts) ->
        assert opts[:override] == true
        assert is_binary(opts[:path])
        assert File.dir?(opts[:path])

      dependency ->
        flunk("unexpected #{name} dependency: #{inspect(dependency)}")
    end
  end

  defp metadata_value(properties, key) do
    properties
    |> Enum.find_value(fn
      {encoded_key, value} when is_binary(encoded_key) ->
        if encoded_key == key, do: decode_metadata(value)

      _other ->
        nil
    end)
  end

  defp decode_metadata(value) when is_binary(value), do: value
  defp decode_metadata(value) when is_list(value), do: Enum.map(value, &decode_metadata/1)
  defp decode_metadata({key, value}), do: {decode_metadata(key), decode_metadata(value)}
  defp decode_metadata(value), do: value

  defp markdown_targets(relative_file) do
    relative_file
    |> then(&Path.join(@root, &1))
    |> File.read!()
    |> then(&Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/u, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp local_target?(target) do
    not String.starts_with?(target, ["#", "http://", "https://", "mailto:"])
  end

  defp assert_local_target!(relative_file, target) do
    path =
      target
      |> String.split("#", parts: 2)
      |> hd()
      |> then(&Path.expand(&1, Path.dirname(Path.join(@root, relative_file))))

    assert File.exists?(path),
           "#{relative_file} links to missing local documentation target #{inspect(target)}"
  end
end
