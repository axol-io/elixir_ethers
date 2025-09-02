defmodule MEVBench do
  @moduledoc """
  Benchmarks for MEV operations.
  
  Run with: mix run bench/mev_bench.exs
  """
  
  alias Ethers.MEV
  alias Ethers.MEV.Bundle
  alias Ethers.MEV.RetryStrategy
  alias Ethers.MEV.BundleState
  
  def run do
    # Setup test data
    transactions = create_test_transactions()
    bundle = create_test_bundle()
    
    Benchee.run(
      %{
        "bundle_creation" => fn -> 
          MEV.create_bundle(transactions, 12345)
        end,
        
        "bundle_validation" => fn ->
          Bundle.validate(bundle)
        end,
        
        "bundle_encoding" => fn ->
          Bundle.encode(bundle)
        end,
        
        "retry_delay_calculation" => fn ->
          strategy = RetryStrategy.exponential()
          RetryStrategy.calculate_delay(strategy, attempt: 5)
        end,
        
        "state_transition" => fn ->
          state = BundleState.new(bundle)
          state
          |> BundleState.mark_submitted("0xhash")
          |> BundleState.mark_included()
        end,
        
        "conflict_detection" => fn ->
          MEV.ConflictDetector.check_conflicts(bundle, [])
        end,
        
        "pipeline_operations" => fn ->
          transactions
          |> MEV.pipe_bundle(block_number: 12345)
          |> MEV.with_timing(min: 1000, max: 2000)
        end
      },
      time: 10,
      memory_time: 2,
      warmup: 2,
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true}
      ]
    )
  end
  
  defp create_test_transactions do
    for i <- 1..10 do
      Base.encode16(:crypto.strong_rand_bytes(32))
    end
  end
  
  defp create_test_bundle do
    {:ok, bundle} = Bundle.new(%{
      transactions: create_test_transactions(),
      block_number: 12345
    })
    bundle
  end
end

# Check if Benchee is available
case Code.ensure_loaded(Benchee) do
  {:module, _} ->
    MEVBench.run()
  
  {:error, _} ->
    IO.puts("""
    Benchee not installed. Add to mix.exs:
    
    {:benchee, "~> 1.0", only: :bench}
    
    Then run: mix deps.get
    """)
end