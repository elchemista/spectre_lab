defmodule Mix.Tasks.SpectreLab.BundleInput do
  @moduledoc false

  @max_bytes 64 * 1_024 * 1_024

  @spec read(String.t()) :: {:ok, binary()} | {:error, :invalid_path | :read_failed | :too_large}
  def read(path) when is_binary(path) and path != "" do
    case File.open(path, [:read, :binary]) do
      {:ok, device} -> read_device(device)
      {:error, _reason} -> {:error, :read_failed}
    end
  end

  def read(_path), do: {:error, :invalid_path}

  @spec unique_switches?([String.t()]) :: boolean()
  def unique_switches?(argv) when is_list(argv) do
    switches =
      argv
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(&switch_name/1)

    length(switches) == length(Enum.uniq(switches))
  end

  defp read_device(device) do
    case IO.binread(device, @max_bytes + 1) do
      data when is_binary(data) and byte_size(data) <= @max_bytes -> {:ok, data}
      data when is_binary(data) -> {:error, :too_large}
      {:error, _reason} -> {:error, :read_failed}
      :eof -> {:ok, ""}
    end
  after
    File.close(device)
  end

  defp switch_name("--no-" <> name), do: switch_name("--" <> name)

  defp switch_name(argument) do
    argument
    |> String.split("=", parts: 2)
    |> hd()
  end
end
