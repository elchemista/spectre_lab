defmodule Spectre.Lab.ServerTool do
  @moduledoc """
  Inspection of the current AgentServer checkpoint or explicit canonical input.

  Decoding proves codec validity only. The runtime separately validates the
  definition fingerprint, identity and recovery invariants before loading it.
  This tool never resumes an owner, executes effects or exposes saved payloads.
  Operational and interaction requests use the core's versioned, redacted
  diagnostic projections. The current checkpoint reference is supplied only by
  the calling runtime, so a Skill cannot inspect a sibling by changing its input.
  """

  alias Spectre.Server.{Checkpoint, Diagnostics}

  def tools(_config) do
    %{
      lab: %{
        contract: 1,
        adapter: __MODULE__,
        default: nil,
        operations: %{inspect: %{path: :cognitive, retry: :safe, max_bytes: 1_048_576}}
      }
    }
  end

  def prepare(:inspect, [:checkpoint], _trusted), do: {:ok, %{scope: :current}}

  def prepare(:inspect, [:checkpoint, :summary], _trusted), do: {:ok, %{scope: :current}}

  def prepare(:inspect, [:checkpoint, :operational], _trusted),
    do: {:ok, %{scope: :current, mode: :operational}}

  def prepare(:inspect, [:interaction, interaction_id], _trusted)
      when is_binary(interaction_id) and byte_size(interaction_id) in 1..256,
      do: {:ok, %{scope: :current, mode: :trace, interaction_id: interaction_id}}

  def prepare(:inspect, [encoded], _trusted) when is_binary(encoded),
    do: {:ok, %{snapshot: encoded}}

  def prepare(_, _, _), do: {:error, :invalid_lab_request}

  def invoke(:inspect, %{scope: :current} = request, %{
        checkpoint_ref: %{adapter: adapter, store: store, key: key}
      }) do
    case adapter.fetch(store, key) do
      {:ok, %{value: snapshot}} when is_binary(snapshot) -> inspect_snapshot(snapshot, request)
      :not_found -> {:error, :checkpoint_not_found}
      {:error, _} = error -> error
      _ -> {:error, :not_a_server_checkpoint}
    end
  end

  def invoke(:inspect, %{scope: :current}, _context), do: {:error, :server_checkpoint_required}
  def invoke(:inspect, %{snapshot: snapshot}, _context), do: inspect_snapshot(snapshot, %{})

  @spec inspect_snapshot(binary(), map()) :: {:ok, map()} | {:error, term()}
  defp inspect_snapshot(snapshot, %{mode: :operational}), do: Diagnostics.checkpoint(snapshot)

  defp inspect_snapshot(snapshot, %{mode: :trace, interaction_id: interaction_id}),
    do: Diagnostics.trace(snapshot, interaction_id)

  defp inspect_snapshot(snapshot, _request), do: summary(snapshot)

  @spec summary(binary()) :: {:ok, map()} | {:error, term()}
  defp summary(snapshot) do
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
