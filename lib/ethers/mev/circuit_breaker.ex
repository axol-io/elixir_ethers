defmodule Ethers.MEV.CircuitBreaker do
  @moduledoc """
  Circuit breaker for MEV operations with functional state management.

  This module implements the circuit breaker pattern using functional
  state transitions. State changes are pure functions that return new
  state values.

  ## States

  - `:closed` - Normal operation, requests pass through
  - `:open` - Circuit tripped, requests fail fast
  - `:half_open` - Testing if service recovered

  ## State Transitions

      closed -> open (threshold failures reached)
      open -> half_open (after timeout)
      half_open -> closed (successful test)
      half_open -> open (test failed)

  ## Example

      # Use the circuit breaker
      CircuitBreaker.call(:flashbots, fn ->
        submit_bundle(bundle)
      end)
  """

  use GenServer

  alias Ethers.MEV.Telemetry
  alias Ethers.MEV.Utils

  @type state_name :: :closed | :open | :half_open
  @type provider :: atom()

  @type circuit_state :: %{
          state: state_name,
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          last_failure_time: DateTime.t() | nil,
          opened_at: DateTime.t() | nil,
          half_open_requests: non_neg_integer()
        }

  @type config :: %{
          threshold: non_neg_integer(),
          timeout: non_neg_integer(),
          half_open_requests: non_neg_integer()
        }

  # Default configuration
  @default_threshold 5
  # 60 seconds
  @default_timeout 60_000
  @default_half_open_requests 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the circuit breaker.

  ## Options
  - `:providers` - List of provider atoms to track (required)
  - `:threshold` - Failure threshold before opening (default: 5)
  - `:timeout` - Time in ms before attempting reset (default: 60000)
  - `:half_open_requests` - Test requests in half-open state (default: 3)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Executes a function through the circuit breaker.

  Returns `{:ok, result}` if successful or `{:error, :circuit_open}` if the
  circuit is open.

  ## Example

      CircuitBreaker.call(:flashbots, fn ->
        submit_bundle(bundle)
      end)
  """
  @spec call(provider(), (-> any())) :: {:ok, any()} | {:error, :circuit_open | term()}
  def call(provider, fun) when is_function(fun, 0) do
    GenServer.call(get_server(), {:call, provider, fun}, :infinity)
  end

  @doc """
  Gets the current state of a circuit.

  Returns the functional state representation.
  """
  @spec get_state(provider()) :: circuit_state()
  def get_state(provider) do
    GenServer.call(get_server(), {:get_state, provider})
  end

  @doc """
  Manually resets a circuit to closed state.

  Useful for administrative intervention.
  """
  @spec reset(provider()) :: :ok
  def reset(provider) do
    GenServer.cast(get_server(), {:reset, provider})
  end

  @doc """
  Gets statistics for all circuits.

  Returns a map of provider -> statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(get_server(), :get_stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    providers = Keyword.fetch!(opts, :providers)

    config = %{
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      half_open_requests: Keyword.get(opts, :half_open_requests, @default_half_open_requests)
    }

    # Initialize circuits for each provider
    circuits =
      providers
      |> Enum.map(fn provider ->
        {provider, initial_state()}
      end)
      |> Map.new()

    state = %{
      circuits: circuits,
      config: config
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:call, provider, fun}, _from, state) do
    circuit = Map.get(state.circuits, provider, initial_state())

    # Check if we should attempt the call based on current state
    case should_attempt?(circuit, state.config) do
      true ->
        # Execute the function and update state based on result
        try do
          result = fun.()
          new_circuit = handle_success(circuit, state.config)
          new_state = put_in(state.circuits[provider], new_circuit)

          emit_success_event(provider, circuit.state)

          {:reply, {:ok, result}, new_state}
        rescue
          error ->
            new_circuit = handle_failure(circuit, state.config)
            new_state = put_in(state.circuits[provider], new_circuit)

            emit_failure_event(provider, circuit.state, error)

            {:reply, {:error, error}, new_state}
        end

      false ->
        emit_circuit_open_event(provider)
        {:reply, {:error, :circuit_open}, state}
    end
  end

  @impl true
  def handle_call({:get_state, provider}, _from, state) do
    circuit = Map.get(state.circuits, provider, initial_state())
    {:reply, circuit, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      state.circuits
      |> Enum.map(fn {provider, circuit} ->
        {provider, circuit_to_stats(circuit, state.config)}
      end)
      |> Map.new()

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:reset, provider}, state) do
    new_state = put_in(state.circuits[provider], initial_state())
    emit_reset_event(provider)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:check_timeout, provider}, state) do
    circuit = Map.get(state.circuits, provider, initial_state())

    new_circuit =
      if should_transition_to_half_open?(circuit, state.config) do
        transition_to_half_open(circuit)
      else
        circuit
      end

    new_state = put_in(state.circuits[provider], new_circuit)

    # Schedule next check if still open
    _ =
      if new_circuit.state == :open do
        Process.send_after(self(), {:check_timeout, provider}, state.config.timeout)
      end

    {:noreply, new_state}
  end

  # ============================================================================
  # Functional State Management
  # ============================================================================

  # Pure function: Create initial state
  defp initial_state do
    %{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      opened_at: nil,
      half_open_requests: 0
    }
  end

  # Pure function: Determine if request should be attempted
  defp should_attempt?(circuit, config) do
    case circuit.state do
      :closed -> true
      :open -> should_transition_to_half_open?(circuit, config)
      :half_open -> circuit.half_open_requests < config.half_open_requests
    end
  end

  # Pure function: Handle successful request
  defp handle_success(circuit, config) do
    case circuit.state do
      :closed ->
        %{circuit | success_count: circuit.success_count + 1, failure_count: 0}

      :half_open ->
        if circuit.half_open_requests + 1 >= config.half_open_requests do
          # Enough successful tests, close the circuit
          transition_to_closed(circuit)
        else
          %{
            circuit
            | half_open_requests: circuit.half_open_requests + 1,
              success_count: circuit.success_count + 1
          }
        end

      :open ->
        # Shouldn't happen, but handle gracefully
        circuit
    end
  end

  # Pure function: Handle failed request
  defp handle_failure(circuit, config) do
    now = DateTime.utc_now()

    case circuit.state do
      :closed ->
        new_failure_count = circuit.failure_count + 1

        if new_failure_count >= config.threshold do
          transition_to_open(circuit, now)
        else
          %{circuit | failure_count: new_failure_count, last_failure_time: now}
        end

      :half_open ->
        # Test failed, reopen the circuit
        transition_to_open(circuit, now)

      :open ->
        # Already open, just update failure time
        %{circuit | last_failure_time: now}
    end
  end

  # Pure function: Transition to open state
  defp transition_to_open(circuit, time) do
    %{circuit | state: :open, opened_at: time, last_failure_time: time, half_open_requests: 0}
  end

  # Pure function: Transition to half-open state
  defp transition_to_half_open(circuit) do
    %{circuit | state: :half_open, half_open_requests: 0}
  end

  # Pure function: Transition to closed state
  defp transition_to_closed(circuit) do
    %{circuit | state: :closed, failure_count: 0, opened_at: nil, half_open_requests: 0}
  end

  # Pure function: Check if should transition from open to half-open
  defp should_transition_to_half_open?(circuit, config) do
    circuit.state == :open and
      circuit.opened_at != nil and
      DateTime.diff(DateTime.utc_now(), circuit.opened_at, :millisecond) >= config.timeout
  end

  # Pure function: Convert circuit state to statistics
  defp circuit_to_stats(circuit, config) do
    %{
      state: circuit.state,
      failure_count: circuit.failure_count,
      success_count: circuit.success_count,
      threshold: config.threshold,
      uptime_percentage: calculate_uptime(circuit),
      time_in_state: calculate_time_in_state(circuit)
    }
  end

  defp calculate_uptime(circuit) do
    total = circuit.success_count + circuit.failure_count

    if total > 0 do
      circuit.success_count / total * 100
    else
      100.0
    end
  end

  defp calculate_time_in_state(%{state: :open, opened_at: opened_at}) when opened_at != nil do
    DateTime.diff(DateTime.utc_now(), opened_at, :second)
  end

  defp calculate_time_in_state(_), do: 0

  # ============================================================================
  # Telemetry Events
  # ============================================================================

  defp emit_success_event(provider, state) do
    Telemetry.emit(
      nil,
      [:circuit_breaker, :call, :success],
      %{count: 1},
      %{provider: provider, state: state}
    )
  end

  defp emit_failure_event(provider, state, error) do
    Telemetry.emit(
      nil,
      [:circuit_breaker, :call, :failure],
      %{count: 1},
      %{provider: provider, state: state, error: inspect(error)}
    )
  end

  defp emit_circuit_open_event(provider) do
    Telemetry.emit(
      nil,
      [:circuit_breaker, :circuit_open],
      %{count: 1},
      %{provider: provider}
    )
  end

  defp emit_reset_event(provider) do
    Telemetry.emit(
      nil,
      [:circuit_breaker, :reset],
      %{count: 1},
      %{provider: provider}
    )
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_server do
    Utils.get_process_via_registry(:circuit_breaker)
  end
end
