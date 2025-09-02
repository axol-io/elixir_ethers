defmodule Ethers.MEV.Supervisor do
  @moduledoc """
  Supervisor for MEV operations with fault tolerance.

  This supervisor manages MEV-related processes with a functional approach
  to configuration and child specifications. It provides fault tolerance
  while maintaining functional principles where possible.

  ## Architecture

  The supervisor uses a rest_for_one strategy with functional child specs:
  - Registry for process discovery (no state)
  - Task supervisor for concurrent operations
  - Circuit breaker with functional state management
  - Health monitor for system status

  ## Example

      # Start the supervisor
      {:ok, _} = Ethers.MEV.Supervisor.start_link()
      
      # Use supervised tasks
      Ethers.MEV.Supervisor.async_submit(bundle, opts)
  """

  use Supervisor

  alias Ethers.MEV.{CircuitBreaker, HealthMonitor, TaskRunner}

  # Supervisor configuration
  @max_restarts 3
  @max_seconds 5
  @shutdown_timeout 5_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the MEV supervisor.

  ## Options
  - `:name` - Supervisor name (default: __MODULE__)
  - `:max_restarts` - Max restarts before shutdown (default: 3)
  - `:max_seconds` - Time window for restarts (default: 5)
  - `:children` - Additional child specifications
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submits a bundle asynchronously using supervised tasks.

  Returns a task that can be awaited or monitored.

  ## Example

      task = Ethers.MEV.Supervisor.async_submit(bundle, opts)
      
      case Task.await(task, 30_000) do
        {:ok, hash} -> IO.puts("Submitted: " <> hash)
        {:error, reason} -> IO.puts("Failed: " <> inspect(reason))
      end
  """
  @spec async_submit(Ethers.MEV.Bundle.t(), keyword()) :: Task.t()
  def async_submit(bundle, opts) do
    TaskRunner.async_submit(bundle, opts)
  end

  @doc """
  Runs a function with circuit breaker protection.

  ## Example

      Ethers.MEV.Supervisor.with_circuit_breaker(:flashbots, fn ->
        submit_bundle(bundle)
      end)
  """
  @spec with_circuit_breaker(atom(), (-> any())) :: {:ok, any()} | {:error, :circuit_open}
  def with_circuit_breaker(provider, fun) do
    CircuitBreaker.call(provider, fun)
  end

  @doc """
  Gets the current health status of MEV operations.

  Returns a map with health metrics for all components.
  """
  @spec health_status() :: map()
  def health_status do
    HealthMonitor.get_status()
  end

  @doc """
  Dynamically adds a child to the supervisor.

  Useful for adding provider-specific processes at runtime.
  """
  @spec add_child(Supervisor.child_spec() | {module(), term()} | module()) ::
          DynamicSupervisor.on_start_child()
  def add_child(child_spec) do
    DynamicSupervisor.start_child(
      {:via, Registry, {Ethers.MEV.Registry, :dynamic_supervisor}},
      child_spec
    )
  end

  # ============================================================================
  # Supervisor Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    max_restarts = Keyword.get(opts, :max_restarts, @max_restarts)
    max_seconds = Keyword.get(opts, :max_seconds, @max_seconds)

    children = build_children(opts)

    Supervisor.init(
      children,
      strategy: :rest_for_one,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    )
  end

  # ============================================================================
  # Child Specifications (Functional Approach)
  # ============================================================================

  defp build_children(opts) do
    base_children = [
      # Registry for process discovery (stateless lookups)
      registry_spec(),

      # Dynamic supervisor for runtime children
      dynamic_supervisor_spec(),

      # Task supervisor for concurrent operations
      task_supervisor_spec(),

      # Circuit breaker with functional state
      circuit_breaker_spec(opts),

      # Health monitoring
      health_monitor_spec(opts),

      # Performance optimizations
      cache_spec(opts),
      connection_pool_spec(opts)
    ]

    # Add any custom children from options
    custom_children = Keyword.get(opts, :children, [])

    base_children ++ custom_children
  end

  defp registry_spec do
    %{
      id: Ethers.MEV.Registry,
      start:
        {Registry, :start_link,
         [
           [
             keys: :unique,
             name: Ethers.MEV.Registry,
             partitions: System.schedulers_online()
           ]
         ]},
      type: :supervisor
    }
  end

  defp dynamic_supervisor_spec do
    %{
      id: Ethers.MEV.DynamicSupervisor,
      start:
        {DynamicSupervisor, :start_link,
         [
           [
             name: {:via, Registry, {Ethers.MEV.Registry, :dynamic_supervisor}},
             strategy: :one_for_one,
             max_restarts: 10,
             max_seconds: 60
           ]
         ]},
      type: :supervisor
    }
  end

  defp task_supervisor_spec do
    %{
      id: Ethers.MEV.TaskSupervisor,
      start:
        {Task.Supervisor, :start_link,
         [
           [
             name: {:via, Registry, {Ethers.MEV.Registry, :task_supervisor}},
             max_children: 100,
             max_restarts: 0,
             max_seconds: 5
           ]
         ]},
      type: :supervisor,
      restart: :permanent,
      shutdown: @shutdown_timeout
    }
  end

  defp circuit_breaker_spec(opts) do
    providers = Keyword.get(opts, :providers, [:flashbots])

    %{
      id: Ethers.MEV.CircuitBreaker,
      start:
        {Ethers.MEV.CircuitBreaker, :start_link,
         [
           [
             name: {:via, Registry, {Ethers.MEV.Registry, :circuit_breaker}},
             providers: providers,
             threshold: 5,
             timeout: 60_000,
             half_open_requests: 3
           ]
         ]},
      type: :worker,
      restart: :permanent,
      shutdown: @shutdown_timeout
    }
  end

  defp health_monitor_spec(opts) do
    check_interval = Keyword.get(opts, :health_check_interval, 30_000)

    %{
      id: Ethers.MEV.HealthMonitor,
      start:
        {Ethers.MEV.HealthMonitor, :start_link,
         [
           [
             name: {:via, Registry, {Ethers.MEV.Registry, :health_monitor}},
             check_interval: check_interval,
             components: [
               :circuit_breaker,
               :task_supervisor,
               :dynamic_supervisor
             ]
           ]
         ]},
      type: :worker,
      restart: :permanent,
      shutdown: @shutdown_timeout
    }
  end

  defp cache_spec(opts) do
    %{
      id: Ethers.MEV.Cache,
      start: {Ethers.MEV.Cache, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: @shutdown_timeout
    }
  end

  defp connection_pool_spec(opts) do
    %{
      id: Ethers.MEV.ConnectionPool,
      start: {Ethers.MEV.ConnectionPool, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: @shutdown_timeout
    }
  end

  # ============================================================================
  # Functional Configuration Builders
  # ============================================================================

  @doc """
  Builds a child spec from functional configuration.

  This allows adding children with pure functional configuration.

  ## Example

      config = %{
        module: MyWorker,
        function: :start_link,
        args: [[name: :my_worker]],
        restart: :permanent
      }
      
      child_spec = Ethers.MEV.Supervisor.build_child_spec(config)
  """
  @spec build_child_spec(map()) :: Supervisor.child_spec()
  def build_child_spec(config) do
    %{
      id: Map.get(config, :id, config.module),
      start: {
        config.module,
        Map.get(config, :function, :start_link),
        Map.get(config, :args, [[]])
      },
      type: Map.get(config, :type, :worker),
      restart: Map.get(config, :restart, :permanent),
      shutdown: Map.get(config, :shutdown, @shutdown_timeout)
    }
  end

  @doc """
  Creates a supervision tree configuration from a functional specification.

  ## Example

      tree = Ethers.MEV.Supervisor.build_tree(%{
        strategy: :one_for_all,
        children: [
          %{module: Worker1, args: [opts1]},
          %{module: Worker2, args: [opts2]}
        ]
      })
  """
  @spec build_tree(%{required(:children) => list(), optional(atom()) => any()}) ::
          {:ok, pid()} | {:error, term()}
  def build_tree(spec) do
    children = Enum.map(spec.children, &build_child_spec/1)

    Supervisor.start_link(
      children,
      strategy: Map.get(spec, :strategy, :one_for_one),
      max_restarts: Map.get(spec, :max_restarts, @max_restarts),
      max_seconds: Map.get(spec, :max_seconds, @max_seconds)
    )
  end

  # ============================================================================
  # Supervision Strategies (Functional Helpers)
  # ============================================================================

  @doc """
  Determines the optimal supervision strategy based on component relationships.

  Returns a strategy atom based on the functional analysis of dependencies.
  """
  @spec recommend_strategy([atom()]) :: atom()
  def recommend_strategy(components) do
    cond do
      # If components are independent, use one_for_one
      independent?(components) -> :one_for_one
      # If components have sequential dependencies, use rest_for_one
      sequential_dependencies?(components) -> :rest_for_one
      # If all components must work together, use one_for_all
      true -> :one_for_all
    end
  end

  defp independent?(components) do
    # Check if components can function independently
    Enum.all?(components, fn component ->
      component in [:task_supervisor, :registry]
    end)
  end

  defp sequential_dependencies?(components) do
    # Check for sequential startup requirements
    :circuit_breaker in components and :health_monitor in components
  end

  @doc """
  Analyzes supervisor metrics and returns optimization recommendations.

  This is a pure function that analyzes restart patterns.
  """
  @spec analyze_restarts(list(map())) :: map()
  def analyze_restarts(restart_history) do
    %{
      total_restarts: length(restart_history),
      restart_frequency: calculate_frequency(restart_history),
      hotspot_processes: identify_hotspots(restart_history),
      recommendations: generate_recommendations(restart_history)
    }
  end

  defp calculate_frequency([]), do: 0

  defp calculate_frequency(history) do
    time_span =
      history
      |> Enum.map(& &1.timestamp)
      |> calculate_time_span()

    if time_span > 0 do
      length(history) / time_span
    else
      0
    end
  end

  defp calculate_time_span([]), do: 0
  defp calculate_time_span([_]), do: 0

  defp calculate_time_span(timestamps) do
    oldest = Enum.min(timestamps)
    newest = Enum.max(timestamps)
    DateTime.diff(newest, oldest, :second)
  end

  defp identify_hotspots(history) do
    history
    |> Enum.group_by(& &1.child_id)
    |> Enum.map(fn {id, restarts} -> {id, length(restarts)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
  end

  defp generate_recommendations(history) do
    restart_count = length(history)

    cond do
      restart_count > 10 ->
        ["Consider increasing restart intensity", "Review error handling in children"]

      restart_count > 5 ->
        ["Monitor for patterns in failures", "Consider circuit breaker for external calls"]

      true ->
        ["System operating normally"]
    end
  end
end
