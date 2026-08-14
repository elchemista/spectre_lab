defmodule SpectreLabFaultCheckpointStoreTest.Store do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    case Agent.get(Keyword.fetch!(opts, :server), &Map.get(&1, ref.key)) do
      nil -> :not_found
      {_revision, checkpoint} -> {:ok, checkpoint}
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(
      Keyword.fetch!(opts, :server),
      &compare_and_swap_entry(&1, ref.key, checkpoint, expected, revision)
    )
  end

  @impl true
  def migrate_instance_key(legacy_ref, stable_ref, legacy, migrated, opts) do
    Agent.get_and_update(
      Keyword.fetch!(opts, :server),
      &migrate_entry(&1, legacy_ref.key, stable_ref.key, legacy, migrated)
    )
  end

  defp compare_and_swap_entry(entries, key, checkpoint, expected, revision) do
    current = Map.get(entries, key)
    actual = if current, do: elem(current, 0), else: 0

    cond do
      current == {revision, checkpoint} ->
        {:ok, entries}

      actual == expected ->
        {:ok, Map.put(entries, key, {revision, checkpoint})}

      true ->
        {{:error, {:stale_checkpoint, actual}}, entries}
    end
  end

  defp migrate_entry(entries, legacy_key, stable_key, legacy, migrated) do
    target = Map.get(entries, stable_key)

    cond do
      target != nil and elem(target, 1) != migrated ->
        {{:error, :migration_conflict}, entries}

      match?({_revision, ^legacy}, Map.get(entries, legacy_key)) ->
        moved = entries |> Map.delete(legacy_key) |> Map.put(stable_key, {0, migrated})
        {{:ok, :moved}, moved}

      target == {0, migrated} ->
        {{:ok, :moved}, entries}

      true ->
        {{:error, :legacy_checkpoint_not_found}, entries}
    end
  end
end

defmodule SpectreLabFaultCheckpointStoreTest do
  use Spectre.Lab.TestCase, async: true

  alias Spectre.AgentRef
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref
  alias Spectre.Lab.Fault.CheckpointStore, as: FaultStore
  alias Spectre.Lab.Fault.Controller

  @delegate SpectreLabFaultCheckpointStoreTest.Store

  test "passes unspecified operations through the public store boundary", context do
    {store, controller, _server} = fault_store(context, %{})
    ref = ref("pass")

    assert :ok = CheckpointStore.persist(store, ref, "checkpoint-1", 0, 1, trace: :portable)
    assert {:ok, "checkpoint-1"} = CheckpointStore.load(store, ref, trace: :portable)

    assert Controller.snapshot(controller) == %{
             calls: %{load: 1, compare_and_swap: 1, migrate_instance_key: 0},
             actions: %{pass: 2, fail_before: 0, commit_then_return: 0},
             remaining: %{load: 0, compare_and_swap: 0, migrate_instance_key: 0}
           }
  end

  test "fails before a write and leaves the delegate untouched", context do
    script = %{compare_and_swap: [{:fail_before, :injected_unavailable}]}
    {store, controller, _server} = fault_store(context, script)
    ref = ref("fail-before")

    assert {:error, :injected_unavailable} =
             CheckpointStore.persist(store, ref, "must-not-commit", 0, 1, [])

    assert :not_found = CheckpointStore.load(store, ref, [])

    assert %{
             actions: %{fail_before: 1},
             remaining: %{compare_and_swap: 0}
           } = Controller.snapshot(controller)
  end

  test "consumes read faults in order and passes after the script is exhausted", context do
    script = %{load: [{:fail_before, :injected_read_failure}]}
    {store, controller, server} = fault_store(context, script)
    ref = ref("read-failure")
    Agent.update(server, &Map.put(&1, ref.key, {1, "present"}))

    assert {:error, :injected_read_failure} = CheckpointStore.load(store, ref, [])
    assert {:ok, "present"} = CheckpointStore.load(store, ref, [])

    assert %{
             calls: %{load: 2},
             actions: %{fail_before: 1, pass: 1},
             remaining: %{load: 0}
           } = Controller.snapshot(controller)
  end

  test "can commit a write and then report the public ambiguous outcome", context do
    script = %{
      compare_and_swap: [
        {:commit_then_return, {:error, {:ambiguous, :injected_lost_ack}}}
      ]
    }

    {store, controller, _server} = fault_store(context, script)
    ref = ref("ambiguous-write")

    assert {:error, {:ambiguous, :injected_lost_ack}} =
             CheckpointStore.persist(store, ref, "committed", 0, 1, [])

    assert {:ok, "committed"} = CheckpointStore.load(store, ref, [])
    assert %{actions: %{commit_then_return: 1}} = Controller.snapshot(controller)
  end

  test "supports fail-before and commit-then-ambiguous key migration", context do
    legacy_ref = ref("legacy")
    stable_ref = ref("stable")

    fail_script = %{migrate_instance_key: [{:fail_before, :migration_offline}]}
    {fail_store, _controller, _server} = fault_store(context, fail_script)

    assert {:error, :migration_offline} =
             CheckpointStore.migrate_instance_key(
               fail_store,
               legacy_ref,
               stable_ref,
               "legacy",
               "migrated",
               []
             )

    ambiguous_script = %{
      migrate_instance_key: [
        {:commit_then_return, {:error, {:ambiguous, :migration_ack_lost}}}
      ]
    }

    {ambiguous_store, _controller, server} = fault_store(context, ambiguous_script)
    Agent.update(server, &Map.put(&1, legacy_ref.key, {1, "legacy"}))

    assert {:error, {:ambiguous, :migration_ack_lost}} =
             CheckpointStore.migrate_instance_key(
               ambiguous_store,
               legacy_ref,
               stable_ref,
               "legacy",
               "migrated",
               []
             )

    assert {:ok, "migrated"} = CheckpointStore.load(ambiguous_store, stable_ref, [])
    assert :not_found = CheckpointStore.load(ambiguous_store, legacy_ref, [])
  end

  test "validates scripts and adapter-reserved options", context do
    assert {:error, :invalid_checkpoint_fault_options} =
             Controller.start_link(%{compare_and_swap: [:pass]})

    assert {:error, :invalid_checkpoint_fault_script} =
             Controller.start_link(script: %{unknown_operation: [:pass]})

    assert {:error, :invalid_checkpoint_fault_script} =
             Controller.start_link(
               script: %{load: [{:commit_then_return, {:error, {:ambiguous, :x}}}]}
             )

    assert {:error, :invalid_checkpoint_fault_options} =
             Controller.start_link(script: %{}, script: %{})

    {:ok, controller} = start_lab_child(context, {Controller, []})
    ref = ref("invalid-config")

    assert {:error, {:invalid_fault_checkpoint_store, {:missing_option, :delegate}}} =
             FaultStore.load(ref, controller: controller)

    assert {:error, {:invalid_fault_checkpoint_store, :invalid_option}} =
             FaultStore.load(ref,
               controller: controller,
               delegate: {FaultStore, []}
             )
  end

  defp fault_store(context, script) do
    {:ok, server} = start_lab_child(context, {Agent, fn -> %{} end})
    {:ok, controller} = start_lab_child(context, {Controller, script: script})

    store =
      {FaultStore, controller: controller, delegate: {@delegate, server: server}}

    assert {:ok, ^store} = CheckpointStore.normalize(store)
    {store, controller, server}
  end

  defp ref(id) do
    id
    |> AgentRef.from_id()
    |> Ref.new("subject-#{id}")
  end
end
