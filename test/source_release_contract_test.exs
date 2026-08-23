defmodule SpectreLab.SourceReleaseContractTest do
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @version "0.1.0"
  @spectre_requirement "~> 0.3.3"
  @ledger_repository "elchemista/spectre_ledger"
  @documentation_files ["README.md", "CHANGELOG.md", "SECURITY.md"] ++
                         Path.wildcard("docs/*.md", match_dot: true)

  test "Mix metadata describes the GitHub-only 0.1.0 source release" do
    config = Mix.Project.config()
    package = Keyword.fetch!(config, :package)

    assert config[:version] == @version
    assert config[:homepage_url] == "https://github.com/elchemista/spectre_lab"

    assert config[:description] ==
             "Verified offline evidence playback and testing tools for Spectre."

    assert package[:name] == "spectre_lab"
    assert package[:maintainers] == ["elchemista"]
    assert package[:licenses] == ["Apache-2.0"]

    assert package[:links] == %{
             "Documentation" => "https://github.com/elchemista/spectre_lab/blob/main/README.md",
             "GitHub" => "https://github.com/elchemista/spectre_lab",
             "Changelog" => "https://github.com/elchemista/spectre_lab/blob/main/CHANGELOG.md"
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

  test "dependency sources are explicit and local paths remain opt-in" do
    source = File.read!(Path.join(@root, "mix.exs"))
    assert source =~ @spectre_requirement
    assert source =~ @ledger_repository
    assert source =~ "404858a4e1e91716a13219e87bf5308f3efd2395"

    assert_dependency(:spectre, @spectre_requirement, nil)
    assert_dependency(:spectre_ledger, nil, @ledger_repository)
  end

  defp assert_dependency(name, requirement, repository) do
    case Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == name)) do
      {^name, ^requirement} ->
        :ok

      {^name, opts} when is_list(opts) ->
        assert opts[:override] == true

        if path = opts[:path] do
          assert File.dir?(path)
        else
          assert opts[:github] == repository
          assert opts[:ref] == "404858a4e1e91716a13219e87bf5308f3efd2395"
        end

      dependency ->
        flunk("unexpected #{name} dependency: #{inspect(dependency)}")
    end
  end

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
