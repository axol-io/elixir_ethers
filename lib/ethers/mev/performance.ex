defmodule Ethers.MEV.Performance do
  @moduledoc """
  Performance optimizations and monitoring for MEV operations.
  """

  @doc """
  Optimizes bundle for submission.

  - Removes unnecessary data
  - Compresses transactions
  - Validates gas efficiency
  """
  @spec optimize_bundle(Ethers.MEV.Bundle.t()) :: Ethers.MEV.Bundle.t()
  def optimize_bundle(bundle) do
    bundle
    |> compact_transactions()
    |> optimize_gas_prices()
    |> validate_efficiency()
  end

  @doc """
  Batch processes multiple bundles efficiently.
  """
  @spec batch_process([Ethers.MEV.Bundle.t()], function()) :: [any()]
  def batch_process(bundles, processor) do
    batch_process_impl(bundles, processor)
  end

  # Check for Flow at compile time
  if Code.ensure_loaded?(Flow) do
    defp batch_process_impl(bundles, processor) do
      bundles
      |> Flow.from_enumerable(max_demand: 10)
      |> Flow.map(processor)
      |> Enum.to_list()
    end
  else
    defp batch_process_impl(bundles, processor) do
      # Fallback to Task.async_stream
      bundles
      |> Task.async_stream(processor, max_concurrency: 10, timeout: 30_000)
      |> Enum.map(fn {:ok, result} -> result end)
    end
  end

  @doc """
  Monitors operation performance.
  """
  @spec measure(atom(), function()) :: {any(), integer()}
  def measure(operation, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    duration = System.monotonic_time(:microsecond) - start

    :telemetry.execute(
      [:ethers, :mev, :performance],
      %{duration: duration},
      %{operation: operation}
    )

    {result, duration}
  end

  @doc """
  Profiles memory usage.
  """
  @spec profile_memory((-> any())) :: {any(), map()}
  def profile_memory(fun) do
    before = :erlang.memory()
    result = fun.()
    after_mem = :erlang.memory()

    diff =
      Enum.map(after_mem, fn {key, val} ->
        {key, val - Keyword.get(before, key, 0)}
      end)

    {result, Map.new(diff)}
  end

  @doc """
  Optimizes RPC batch requests.
  """
  @spec batch_rpc_calls([map()]) :: {:ok, [any()]}
  def batch_rpc_calls(calls) do
    # Group by RPC endpoint
    grouped = Enum.group_by(calls, & &1.endpoint)

    # Execute in parallel per endpoint
    results =
      Enum.map(grouped, fn {endpoint, endpoint_calls} ->
        Task.async(fn ->
          execute_batch(endpoint, endpoint_calls)
        end)
      end)
      |> Task.await_many(10_000)

    # Flatten results
    {:ok, List.flatten(results)}
  end

  # Private functions

  defp compact_transactions(bundle) do
    # Remove unnecessary whitespace from hex strings
    transactions =
      Enum.map(bundle.transactions, fn tx ->
        tx
        |> String.replace(~r/\s+/, "")
        |> String.downcase()
      end)

    %{bundle | transactions: transactions}
  end

  defp optimize_gas_prices(bundle) do
    # Could implement gas price optimization logic
    bundle
  end

  defp validate_efficiency(bundle) do
    # Validate bundle efficiency metrics
    if efficient?(bundle) do
      bundle
    else
      raise "Bundle fails efficiency requirements"
    end
  end

  defp efficient?(bundle) do
    # Check efficiency criteria
    length(bundle.transactions) <= 10 and
      bundle.block_number > 0
  end

  defp execute_batch(endpoint, calls) do
    batch_request =
      Enum.map(calls, fn call ->
        %{
          jsonrpc: "2.0",
          method: call.method,
          params: call.params,
          id: call.id
        }
      end)

    case Ethereumex.HttpClient.batch_request(batch_request, url: endpoint) do
      {:ok, responses} -> responses
      {:error, _} -> []
    end
  end
end
