defmodule Mix.Tasks.SpectreLab.Gen.Support do
  @moduledoc false

  @module_pattern ~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/

  @type plan :: %{
          required(:assigns) => keyword(),
          required(:destination) => String.t(),
          required(:display_path) => String.t(),
          required(:exists?) => boolean(),
          required(:template) => String.t()
        }

  @doc false
  @spec module_name!(term()) :: String.t() | no_return()
  def module_name!(module) when is_binary(module) do
    if Regex.match?(@module_pattern, module) and module != "Elixir" and
         not String.starts_with?(module, "Elixir.") do
      module
    else
      Mix.raise(
        "invalid module name #{inspect(module)}; expected an alias such as MyApp.PlaybackTest"
      )
    end
  end

  def module_name!(module) do
    Mix.raise(
      "invalid module name #{inspect(module)}; expected an alias such as MyApp.PlaybackTest"
    )
  end

  @doc false
  @spec plan_test!(String.t(), String.t(), boolean()) :: plan() | no_return()
  def plan_test!(module, directory, force?) do
    root = File.cwd!() |> Path.expand()
    relative_directory = relative_directory!(directory, root)
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)
    destination = Path.join([root, relative_directory, module_path <> ".exs"])
    template = template!()

    inspect_parents!(Path.dirname(destination), root)
    exists? = inspect_target!(destination, force?)

    %{
      assigns: [module: module],
      destination: destination,
      display_path: Path.relative_to(destination, root),
      exists?: exists?,
      template: template
    }
  end

  @doc false
  @spec write!(plan(), boolean(), boolean()) :: :ok
  def write!(plan, dry_run?, force?) do
    Mix.shell().info("#{action(plan, dry_run?)} #{plan.display_path}")

    unless dry_run? do
      write_template!(plan, force?)
    end

    :ok
  end

  @doc false
  @spec reject_duplicate_options!(keyword()) :: :ok | no_return()
  def reject_duplicate_options!(opts) do
    case duplicate_key(opts) do
      nil -> :ok
      key -> Mix.raise("option --#{option_name(key)} may only be passed once")
    end
  end

  @spec relative_directory!(term(), String.t()) :: String.t() | no_return()
  defp relative_directory!(directory, root)
       when is_binary(directory) and byte_size(directory) > 0 do
    expanded = Path.expand(directory, root)
    relative = Path.relative_to(expanded, root)

    if safe_relative_path?(directory, relative) do
      relative
    else
      Mix.raise("test path must stay inside the current project")
    end
  end

  defp relative_directory!(_directory, _root) do
    Mix.raise("test path must be a non-empty relative directory")
  end

  @spec safe_relative_path?(String.t(), String.t()) :: boolean()
  defp safe_relative_path?(directory, relative) do
    Path.type(directory) == :relative and
      String.trim(directory) != "" and
      Path.type(relative) == :relative and
      not match?([".." | _rest], Path.split(relative))
  end

  @spec inspect_parents!(String.t(), String.t()) :: :ok | no_return()
  defp inspect_parents!(directory, root) do
    _parent =
      directory
      |> Path.relative_to(root)
      |> path_segments()
      |> Enum.reduce(root, fn segment, parent ->
        path = Path.join(parent, segment)
        inspect_parent!(path)
        path
      end)

    :ok
  end

  @spec path_segments(String.t()) :: [String.t()]
  defp path_segments("."), do: []
  defp path_segments(relative), do: Path.split(relative)

  @spec inspect_parent!(String.t()) :: :ok | no_return()
  defp inspect_parent!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        Mix.raise("generator parent is a symlink: #{path}")

      {:ok, %File.Stat{type: type}} ->
        Mix.raise("generator parent is not a directory (#{type}): #{path}")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise("cannot inspect generator parent #{path}: #{inspect(reason)}")
    end
  end

  @spec inspect_target!(String.t(), boolean()) :: boolean() | no_return()
  defp inspect_target!(destination, force?) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        false

      {:ok, %File.Stat{type: :regular, links: 1}} when force? ->
        true

      {:ok, %File.Stat{type: :regular}} when force? ->
        Mix.raise("--force refuses files with multiple hard links: #{destination}")

      {:ok, %File.Stat{type: :regular}} ->
        Mix.raise("refusing to overwrite #{destination}; pass --force to replace it")

      {:ok, %File.Stat{type: type}} ->
        Mix.raise("--force only replaces regular files; #{destination} is #{type}")

      {:error, reason} ->
        Mix.raise("cannot inspect #{destination}: #{inspect(reason)}")
    end
  end

  @spec template!() :: String.t() | no_return()
  defp template! do
    path =
      Application.app_dir(
        :spectre_lab,
        "priv/templates/spectre_lab.gen.test/playback_test.exs.eex"
      )

    if File.regular?(path),
      do: path,
      else: Mix.raise("Spectre Lab test template is missing: #{path}")
  end

  @spec write_template!(plan(), boolean()) :: :ok | no_return()
  defp write_template!(plan, force?) do
    destination_directory = Path.dirname(plan.destination)
    File.mkdir_p!(destination_directory)

    temporary =
      Path.join(
        destination_directory,
        ".spectre_lab_gen_#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    try do
      Mix.Generator.copy_template(
        plan.template,
        temporary,
        plan.assigns,
        force: false,
        quiet: true,
        format_elixir: true
      )

      replace_target!(temporary, plan.destination, plan.exists?, force?)
    after
      File.rm(temporary)
    end
  end

  @spec replace_target!(String.t(), String.t(), boolean(), boolean()) :: :ok | no_return()
  defp replace_target!(temporary, destination, false, _force?) do
    # A POSIX rename replaces a target that appears after preflight. Creating a
    # hard link publishes the same-directory temporary file atomically while
    # preserving the generator's no-overwrite contract.
    case File.ln(temporary, destination) do
      :ok -> :ok
      {:error, :eexist} -> Mix.raise("refusing to overwrite #{destination}")
      {:error, reason} -> Mix.raise("cannot create #{destination}: #{inspect(reason)}")
    end
  end

  defp replace_target!(temporary, destination, true, true) do
    # Re-check the target immediately before the atomic same-directory rename;
    # this prevents truncating an external inode through a hard link and narrows
    # the preflight/write race to one fail-closed replacement check.
    true = inspect_target!(destination, true)

    case File.rename(temporary, destination) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cannot replace #{destination}: #{inspect(reason)}")
    end
  end

  @spec duplicate_key(keyword()) :: atom() | nil
  defp duplicate_key(opts) do
    opts
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)
  end

  @spec option_name(atom()) :: String.t()
  defp option_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  @spec action(plan(), boolean()) :: String.t()
  defp action(%{exists?: true}, true), do: "would overwrite"
  defp action(_plan, true), do: "would create"
  defp action(%{exists?: true}, false), do: "overwrite"
  defp action(_plan, false), do: "create"
end
