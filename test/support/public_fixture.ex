defmodule SpectreLab.PublicFixture.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreLab.PublicFixture.Agent do
  @moduledoc false

  use Spectre.Agent, id: :spectre_lab_public_fixture

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :public_fixture do
    on :MESSAGE, regex: ~r/\S/u do
      reply(:fixture, renderer: {SpectreLab.PublicFixture.Renderer, :render})
    end
  end
end

defmodule SpectreLab.PublicFixture do
  @moduledoc false

  alias Spectre.AgentRef
  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Ref
  alias Spectre.Subject

  @agent SpectreLab.PublicFixture.Agent
  @static_bundle Path.expand("../fixtures/ledger-bundle-v1.json.base64", __DIR__)

  def static_bundle! do
    @static_bundle
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end

  def timeline!(server, label, inputs \\ ["first", "second"]) do
    unique = System.unique_integer([:positive, :monotonic])
    subject = Subject.new("#{label}-#{unique}")
    ref = Ref.new(AgentRef.new(@agent), subject)
    ledger_opts = ledger_opts(server, "#{label}-#{unique}")

    %{ref: ref, subject: subject, ledger_opts: ledger_opts}
    |> continue!(inputs)
  end

  def divergent!(left_server, right_server, label) do
    %{ref: ref, subject: subject, ledger_opts: left_opts, bundles: [common]} =
      timeline!(left_server, "#{label}-common", ["common"])

    right_opts = ledger_opts(right_server, Keyword.fetch!(left_opts, :namespace))

    {:ok, import_status, _report} = Spectre.Ledger.import_bundle(common, right_opts)
    true = import_status in [:imported, :idempotent]

    %{bundles: [left]} =
      continue!(
        %{ref: ref, subject: subject, ledger_opts: left_opts},
        ["left branch"]
      )

    %{bundles: [right]} =
      continue!(
        %{ref: ref, subject: subject, ledger_opts: right_opts},
        ["right branch"]
      )

    %{ref: ref, common: common, left: left, right: right}
  end

  defp continue!(fixture, inputs) do
    %{ref: ref, subject: subject, ledger_opts: ledger_opts} = fixture

    {:ok, instance} =
      Spectre.summon(
        agent: @agent,
        subject: subject,
        checkpoint_store: Spectre.Ledger.checkpoint_store(ledger_opts),
        checkpoint_mode: :manual,
        idle: false
      )

    bundles =
      try do
        Enum.map(inputs, fn input ->
          {:ok, turn} = Spectre.turn(instance, input)
          {:reply, _result} = turn.decision
          {:ok, _revision} = flush_current(instance)
          {:ok, bundle} = Spectre.Ledger.export_bundle(ref, ledger_opts)
          bundle
        end)
      after
        if Process.alive?(instance), do: GenServer.stop(instance, :normal)
      end

    Map.merge(fixture, %{bundles: bundles, instance: instance})
  end

  defp flush_current(instance, attempts \\ 5)

  defp flush_current(_instance, 0), do: {:error, :checkpoint_did_not_settle}

  defp flush_current(instance, attempts) do
    with {:ok, persisted_revision} <- Spectre.flush_checkpoint(instance),
         {:ok, checkpoint} <- Spectre.checkpoint(instance),
         {:ok, report} <- Foundation.verify_instance_checkpoint(checkpoint) do
      if report.revision == persisted_revision,
        do: {:ok, persisted_revision},
        else: flush_current(instance, attempts - 1)
    end
  end

  defp ledger_opts(server, namespace) do
    [backend: :memory, server: server, namespace: namespace]
  end
end
