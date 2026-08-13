defmodule Spectre.Lab.Sandbox do
  @moduledoc """
  Caller-owned supervision boundary for Lab resources.

  A sandbox is never registered. Start it from the caller's supervision tree
  and use `start_child/2` for every process that belongs to a test. Stopping the
  sandbox then shuts those children down as one supervised unit.

  The accepted option surface is intentionally small: `:max_children` may be a
  non-negative integer or `:infinity`.
  """

  use DynamicSupervisor

  @type option :: {:max_children, non_neg_integer() | :infinity}
  @type child_spec ::
          Supervisor.child_spec()
          | {module(), term()}
          | module()
          | :supervisor.child_spec()
  @type child ::
          {:undefined, pid() | :restarting, :worker | :supervisor, [module()] | :dynamic}

  @doc "Starts an unregistered sandbox linked to the caller."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    with {:ok, flags} <- normalize_options(opts) do
      DynamicSupervisor.start_link(__MODULE__, flags)
    end
  end

  @doc "Starts one child under `sandbox`."
  @spec start_child(pid(), child_spec()) :: DynamicSupervisor.on_start_child()
  def start_child(sandbox, child_spec) when is_pid(sandbox) do
    DynamicSupervisor.start_child(sandbox, child_spec)
  end

  def start_child(_sandbox, _child_spec), do: {:error, :invalid_lab_sandbox}

  @doc "Stops a child and removes it from `sandbox`."
  @spec terminate_child(pid(), pid()) :: :ok | {:error, :not_found}
  def terminate_child(sandbox, child) when is_pid(sandbox) and is_pid(child) do
    DynamicSupervisor.terminate_child(sandbox, child)
  end

  def terminate_child(_sandbox, _child), do: {:error, :not_found}

  @doc "Returns the currently supervised children without introducing names."
  @spec children(pid()) :: [child()]
  def children(sandbox) when is_pid(sandbox), do: DynamicSupervisor.which_children(sandbox)

  @impl true
  def init(flags), do: DynamicSupervisor.init(flags)

  @spec normalize_options(term()) :: {:ok, keyword()} | {:error, term()}
  defp normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_option_keys(opts),
         {:ok, max_children} <-
           normalize_max_children(Keyword.get(opts, :max_children, :infinity)) do
      {:ok, [strategy: :one_for_one, max_children: max_children]}
    else
      false -> {:error, :invalid_lab_sandbox_options}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_options(_opts), do: {:error, :invalid_lab_sandbox_options}

  @spec validate_option_keys(keyword()) :: :ok | {:error, term()}
  defp validate_option_keys(opts) do
    if Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
         Enum.all?(Keyword.keys(opts), &(&1 == :max_children)) do
      :ok
    else
      {:error, :invalid_lab_sandbox_options}
    end
  end

  @spec normalize_max_children(term()) ::
          {:ok, non_neg_integer() | :infinity} | {:error, term()}
  defp normalize_max_children(:infinity), do: {:ok, :infinity}
  defp normalize_max_children(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_max_children(_value), do: {:error, :invalid_lab_sandbox_max_children}
end
