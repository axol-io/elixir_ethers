defmodule Ethers.MEV.HealthMonitor do
  @moduledoc """
  Health monitoring for MEV system components with functional health checks.

  This module provides health monitoring using pure functions for health
  assessment and functional composition of health checks.

  ## Health States

  - `:healthy` - Component operating normally
  - `:degraded` - Component operational but with issues
  - `:unhealthy` - Component not operational

  ## Example

      status = HealthMonitor.get_status()
      
      if status.overall_health == :healthy do
        proceed_with_operations()
      else
        handle_degraded_state(status)
      end
  """

  use GenServer

  alias Ethers.MEV.Utils

  alias Ethers.MEV.{CircuitBreaker, Telemetry}

  @type health_state :: :healthy | :degraded | :unhealthy
  @type component :: atom()

  @type health_status :: %{
          component: component(),
          state: health_state,
          details: map(),
          last_check: DateTime.t(),
          metrics: map()
        }

  @type health_check :: %{
          name: atom(),
          check_fn: (-> health_state()),
          weight: number()
        }

  # Check interval in milliseconds
  @default_check_interval 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the health monitor.

  ## Options
  - `:check_interval` - Interval between health checks in ms (default: 30000)
  - `:components` - List of components to monitor
  - `:checks` - Custom health check functions
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Gets the current health status of all components.

  Returns a map with overall health and individual component statuses.
  """
  @spec get_status() :: map()
  def get_status do
    GenServer.call(get_server(), :get_status)
  end

  @doc """
  Gets health status for a specific component.
  """
  @spec get_component_status(component()) :: health_status() | nil
  def get_component_status(component) do
    GenServer.call(get_server(), {:get_component_status, component})
  end

  @doc """
  Registers a custom health check.

  The check function should return :healthy, :degraded, or :unhealthy.

  ## Example

      HealthMonitor.register_check(:database, fn ->
        case check_database_connection() do
          :ok -> :healthy
          {:error, :timeout} -> :degraded
          {:error, _} -> :unhealthy
        end
      end)
  """
  @spec register_check(atom(), (-> health_state()), keyword()) :: :ok
  def register_check(name, check_fn, opts \\ []) when is_function(check_fn, 0) do
    GenServer.cast(get_server(), {:register_check, name, check_fn, opts})
  end

  @doc """
  Forces an immediate health check for all components.
  """
  @spec check_now() :: map()
  def check_now do
    GenServer.call(get_server(), :check_now)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    components = Keyword.get(opts, :components, [:circuit_breaker, :task_supervisor])

    # Build initial health checks
    checks = build_default_checks(components)

    # Schedule first check
    Process.send_after(self(), :perform_health_check, check_interval)

    state = %{
      check_interval: check_interval,
      checks: checks,
      statuses: %{},
      last_check: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = build_status_response(state)
    {:reply, status, state}
  end

  @impl true
  def handle_call({:get_component_status, component}, _from, state) do
    status = Map.get(state.statuses, component)
    {:reply, status, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    new_statuses = perform_all_checks(state.checks)
    new_state = %{state | statuses: new_statuses, last_check: DateTime.utc_now()}

    status = build_status_response(new_state)
    {:reply, status, new_state}
  end

  @impl true
  def handle_cast({:register_check, name, check_fn, opts}, state) do
    weight = Keyword.get(opts, :weight, 1.0)

    check = %{
      name: name,
      check_fn: check_fn,
      weight: weight
    }

    new_checks = Map.put(state.checks, name, check)
    {:noreply, %{state | checks: new_checks}}
  end

  @impl true
  def handle_info(:perform_health_check, state) do
    new_statuses = perform_all_checks(state.checks)
    new_state = %{state | statuses: new_statuses, last_check: DateTime.utc_now()}

    # Emit telemetry
    emit_health_telemetry(new_state)

    # Schedule next check
    Process.send_after(self(), :perform_health_check, state.check_interval)

    {:noreply, new_state}
  end

  # ============================================================================
  # Health Check Functions (Pure)
  # ============================================================================

  defp build_default_checks(components) do
    components
    |> Enum.map(fn component ->
      {component, build_component_check(component)}
    end)
    |> Map.new()
  end

  defp build_component_check(:circuit_breaker) do
    %{
      name: :circuit_breaker,
      check_fn: &check_circuit_breaker/0,
      # Circuit breaker is critical
      weight: 2.0
    }
  end

  defp build_component_check(:task_supervisor) do
    %{
      name: :task_supervisor,
      check_fn: &check_task_supervisor/0,
      weight: 1.5
    }
  end

  defp build_component_check(:dynamic_supervisor) do
    %{
      name: :dynamic_supervisor,
      check_fn: &check_dynamic_supervisor/0,
      weight: 1.0
    }
  end

  defp build_component_check(_) do
    %{
      name: :unknown,
      check_fn: fn -> :healthy end,
      weight: 1.0
    }
  end

  # Pure function: Check circuit breaker health
  defp check_circuit_breaker do
    try do
      stats = CircuitBreaker.get_stats()

      # Analyze circuit states
      open_circuits =
        stats
        |> Enum.filter(fn {_provider, stat} -> stat.state == :open end)
        |> length()

      total_circuits = map_size(stats)

      cond do
        open_circuits == 0 -> :healthy
        open_circuits < total_circuits / 2 -> :degraded
        true -> :unhealthy
      end
    rescue
      _ -> :unhealthy
    end
  end

  # Pure function: Check task supervisor health
  defp check_task_supervisor do
    try do
      case Registry.lookup(Ethers.MEV.Registry, :task_supervisor) do
        [{pid, _}] when is_pid(pid) ->
          if Process.alive?(pid) do
            # Check task count
            children = Task.Supervisor.children(pid)

            cond do
              length(children) < 50 -> :healthy
              length(children) < 80 -> :degraded
              true -> :unhealthy
            end
          else
            :unhealthy
          end

        _ ->
          :unhealthy
      end
    rescue
      _ -> :unhealthy
    end
  end

  # Pure function: Check dynamic supervisor health
  defp check_dynamic_supervisor do
    try do
      case Registry.lookup(Ethers.MEV.Registry, :dynamic_supervisor) do
        [{pid, _}] when is_pid(pid) ->
          if Process.alive?(pid) do
            :healthy
          else
            :unhealthy
          end

        _ ->
          :unhealthy
      end
    rescue
      _ -> :unhealthy
    end
  end

  # Pure function: Perform all health checks
  defp perform_all_checks(checks) do
    checks
    |> Enum.map(fn {name, check} ->
      status = perform_single_check(check)
      {name, status}
    end)
    |> Map.new()
  end

  # Pure function: Perform a single health check
  defp perform_single_check(check) do
    start_time = System.monotonic_time(:millisecond)

    state =
      try do
        check.check_fn.()
      rescue
        _ -> :unhealthy
      end

    duration = System.monotonic_time(:millisecond) - start_time

    %{
      component: check.name,
      state: state,
      details: %{
        weight: check.weight,
        check_duration_ms: duration
      },
      last_check: DateTime.utc_now(),
      metrics: calculate_metrics(state, check.weight)
    }
  end

  # Pure function: Calculate health metrics
  defp calculate_metrics(:healthy, weight), do: %{score: 100.0 * weight}
  defp calculate_metrics(:degraded, weight), do: %{score: 50.0 * weight}
  defp calculate_metrics(:unhealthy, weight), do: %{score: 0.0 * weight}

  # Pure function: Build status response
  defp build_status_response(state) do
    overall_health = calculate_overall_health(state.statuses)
    health_score = calculate_health_score(state.statuses)

    %{
      overall_health: overall_health,
      health_score: health_score,
      last_check: state.last_check,
      components: state.statuses,
      recommendations: generate_recommendations(state.statuses)
    }
  end

  # Pure function: Calculate overall health
  defp calculate_overall_health(statuses) when map_size(statuses) == 0, do: :healthy

  defp calculate_overall_health(statuses) do
    states =
      statuses
      |> Map.values()
      |> Enum.map(& &1.state)

    cond do
      :unhealthy in states -> :unhealthy
      :degraded in states -> :degraded
      true -> :healthy
    end
  end

  # Pure function: Calculate health score
  defp calculate_health_score(statuses) when map_size(statuses) == 0, do: 100.0

  defp calculate_health_score(statuses) do
    {total_score, total_weight} =
      statuses
      |> Map.values()
      |> Enum.reduce({0.0, 0.0}, fn status, {score, weight} ->
        component_weight = get_in(status, [:details, :weight]) || 1.0
        component_score = get_in(status, [:metrics, :score]) || 0.0

        {score + component_score, weight + component_weight}
      end)

    if total_weight > 0 do
      total_score / total_weight
    else
      0.0
    end
  end

  # Pure function: Generate recommendations
  defp generate_recommendations(statuses) do
    statuses
    |> Enum.flat_map(fn {component, status} ->
      case status.state do
        :unhealthy ->
          ["#{component} is unhealthy - investigate immediately"]

        :degraded ->
          ["#{component} is degraded - monitor closely"]

        _ ->
          []
      end
    end)
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  defp emit_health_telemetry(state) do
    overall_health = calculate_overall_health(state.statuses)
    health_score = calculate_health_score(state.statuses)

    Telemetry.emit(
      nil,
      [:health_monitor, :check],
      %{
        health_score: health_score,
        component_count: map_size(state.statuses)
      },
      %{
        overall_health: overall_health,
        components: Map.keys(state.statuses)
      }
    )
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_server do
    Utils.get_process_via_registry(:health_monitor)
  end
end
