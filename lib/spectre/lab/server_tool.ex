defmodule Spectre.Lab.ServerTool do
  @moduledoc """
  Offline inspection of an AgentServer checkpoint's canonical representation.

  Decoding proves codec validity only. The runtime separately validates the
  definition fingerprint, identity and recovery invariants before loading it.
  This tool never resumes an owner, executes effects or exposes saved payloads.
  """

  alias Spectre.Server.Checkpoint

  def tools(_config) do
    %{
      lab: %{
        contract: 1,
        adapter: __MODULE__,
        default: nil,
        operations: %{inspect: %{path: :cognitive, retry: :safe, max_bytes: 16_777_216}}
      }
    }
  end

  def prepare(:inspect, [encoded], _trusted) when is_binary(encoded),
    do: {:ok, %{snapshot: encoded}}

  def prepare(_, _, _), do: {:error, :invalid_lab_request}

  def invoke(:inspect, %{snapshot: snapshot}, _context) do
    with {:ok, projection} <- Checkpoint.decode_snapshot(snapshot),
         true <- is_map(projection) and not is_struct(projection),
         true <- Enum.all?([:outbox, :inbox, :pending], &is_map(Map.get(projection, &1))),
         version when is_integer(version) and version > 0 <- Map.get(projection, :version),
         sequence when is_integer(sequence) and sequence >= 0 <- Map.get(projection, :sequence) do
      {:ok,
       %{
         codec_valid: true,
         version: version,
         pending: map_size(projection.pending),
         outbox: map_size(projection.outbox),
         inbox: map_size(projection.inbox),
         sequence: sequence,
         fingerprint_present: Map.has_key?(projection, :definition_fingerprint)
       }}
    else
      false -> {:error, :not_a_server_checkpoint}
      {:error, _} = error -> error
      _ -> {:error, :not_a_server_checkpoint}
    end
  end

  def project(:inspect, result), do: {:ok, result}
end
