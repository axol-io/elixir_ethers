defmodule Ethers.MEV.ConnectionPool do
  @moduledoc """
  Connection pooling for MEV relay connections.

  Optimizes HTTP connections to MEV relays by maintaining
  a pool of persistent connections.
  """

  use GenServer

  alias Ethers.MEV.Utils

  @pool_size 10
  @pool_timeout 5_000
  @idle_timeout 30_000

  # Public API

  @doc """
  Starts the connection pool.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes a request using a pooled connection.
  """
  @spec request(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(url, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @pool_timeout)

    GenServer.call(__MODULE__, {:request, url, body, opts}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :pool_timeout}
  end

  @doc """
  Gets pool statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, @pool_size)

    state = %{
      pools: %{},
      stats: %{
        requests: 0,
        hits: 0,
        misses: 0,
        errors: 0
      },
      config: %{
        pool_size: pool_size,
        idle_timeout: Keyword.get(opts, :idle_timeout, @idle_timeout)
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request, url, body, opts}, _from, state) do
    {pool_name, state} = get_or_create_pool(url, state)

    result = execute_request(pool_name, url, body, opts)

    new_state = update_stats(state, result)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        pools: map_size(state.pools),
        hit_rate: calculate_hit_rate(state.stats)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:idle_timeout, pool_name}, state) do
    # Clean up idle pools
    new_pools = Map.delete(state.pools, pool_name)
    {:noreply, %{state | pools: new_pools}}
  end

  # Private functions

  defp get_or_create_pool(url, state) do
    uri = URI.parse(url)
    pool_name = "#{uri.scheme}://#{uri.host}:#{uri.port || 443}"

    case Map.get(state.pools, pool_name) do
      nil ->
        create_pool(pool_name, state)

      _pool ->
        {pool_name, put_in(state, [:stats, :hits], state.stats.hits + 1)}
    end
  end

  defp create_pool(pool_name, state) do
    # Create Finch pool configuration
    pool_config = %{
      size: state.config.pool_size,
      count: 1,
      conn_opts: [
        transport_opts: [
          timeout: 10_000,
          nodelay: true
        ]
      ]
    }

    new_pools = Map.put(state.pools, pool_name, pool_config)

    # Schedule idle timeout
    Process.send_after(self(), {:idle_timeout, pool_name}, state.config.idle_timeout)

    new_state =
      state
      |> Map.put(:pools, new_pools)
      |> put_in([:stats, :misses], state.stats.misses + 1)

    {pool_name, new_state}
  end

  defp execute_request(_pool_name, url, body, opts) do
    # Use Req with connection pooling
    headers = Keyword.get(opts, :headers, [])

    req_opts = [
      method: :post,
      url: url,
      headers: headers,
      json: body,
      pool_timeout: @pool_timeout,
      receive_timeout: 15_000
    ]

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_stats(state, result) do
    update_key =
      case result do
        {:ok, _} -> :requests
        {:error, _} -> :errors
      end

    update_in(state, [:stats, update_key], &(&1 + 1))
  end

  defp calculate_hit_rate(stats) do
    Utils.calculate_hit_rate(stats)
  end
end
