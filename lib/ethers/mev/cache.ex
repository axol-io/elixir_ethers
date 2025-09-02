defmodule Ethers.MEV.Cache do
  @moduledoc """
  ETS-based caching for MEV bundle states and simulation results.

  Provides fast, concurrent access to frequently accessed data.
  """

  use GenServer

  alias Ethers.MEV.Utils

  @table_name :mev_cache
  # 1 minute
  @default_ttl 60_000
  # 30 seconds
  @cleanup_interval 30_000
  @max_size 10_000

  # Public API

  @doc """
  Starts the cache process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a value from cache.
  """
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expiry}] ->
        if System.monotonic_time(:millisecond) < expiry do
          {:ok, value}
        else
          :ets.delete(@table_name, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Puts a value in cache with TTL.
  """
  @spec put(term(), term(), integer()) :: :ok
  def put(key, value, ttl \\ @default_ttl) do
    expiry = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table_name, {key, value, expiry})
    :ok
  end

  @doc """
  Deletes a value from cache.
  """
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Gets or computes a value.
  """
  @spec fetch(term(), (-> term()), integer()) :: term()
  def fetch(key, fun, ttl \\ @default_ttl) do
    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, ttl)
        value
    end
  end

  @doc """
  Caches bundle state.
  """
  @spec cache_bundle_state(String.t(), map()) :: :ok
  def cache_bundle_state(bundle_hash, state) do
    put({:bundle_state, bundle_hash}, state)
  end

  @doc """
  Gets cached bundle state.
  """
  @spec get_bundle_state(String.t()) :: {:ok, map()} | :miss
  def get_bundle_state(bundle_hash) do
    get({:bundle_state, bundle_hash})
  end

  @doc """
  Caches simulation result.
  """
  @spec cache_simulation(String.t(), map()) :: :ok
  def cache_simulation(bundle_hash, result) do
    # 30s TTL
    put({:simulation, bundle_hash}, result, 30_000)
  end

  @doc """
  Gets cached simulation.
  """
  @spec get_simulation(String.t()) :: {:ok, map()} | :miss
  def get_simulation(bundle_hash) do
    get({:simulation, bundle_hash})
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clears the cache.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    # Create ETS table
    _table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Schedule cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    state = %{
      max_size: Keyword.get(opts, :max_size, @max_size),
      stats: %{
        hits: 0,
        misses: 0,
        evictions: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(@table_name, :size)

    stats =
      Map.merge(state.stats, %{
        size: size,
        memory: :ets.info(@table_name, :memory),
        hit_rate: calculate_hit_rate(state.stats)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, %{state | stats: %{hits: 0, misses: 0, evictions: 0}}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    evicted = cleanup_expired()

    # Check size limit
    size = :ets.info(@table_name, :size)

    new_state =
      if size > state.max_size do
        additional_evicted = evict_lru(size - state.max_size)
        update_in(state, [:stats, :evictions], &(&1 + evicted + additional_evicted))
      else
        update_in(state, [:stats, :evictions], &(&1 + evicted))
      end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:noreply, new_state}
  end

  # Private functions

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.select(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))

    length(expired)
  end

  defp evict_lru(count) do
    # Simple LRU: evict oldest entries
    entries =
      :ets.tab2list(@table_name)
      |> Enum.sort_by(fn {_, _, expiry} -> expiry end)
      |> Enum.take(count)

    Enum.each(entries, fn {key, _, _} ->
      :ets.delete(@table_name, key)
    end)

    length(entries)
  end

  defp calculate_hit_rate(stats) do
    Utils.calculate_hit_rate(stats)
  end
end
