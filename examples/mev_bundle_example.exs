#!/usr/bin/env elixir

# MEV Bundle Example
# 
# This example demonstrates how to create and submit MEV bundles using
# the Elixir Ethers library.
#
# Prerequisites:
# - Anvil running locally (for testing)
# - Private key with ETH balance
#
# Run with: elixir examples/mev_bundle_example.exs

Mix.install([
  {:ethers, path: "."},
  {:jason, "~> 1.4"},
  {:req, "~> 0.5"},
  {:ex_secp256k1, "~> 0.7"}
])

defmodule MEVBundleExample do
  alias Ethers.MEV
  alias Ethers.Transaction
  alias Ethers.Signer.Local
  alias Ethers.Utils
  
  # Test accounts from Anvil
  @from_account %{
    address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    private_key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  }
  
  @to_account %{
    address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    private_key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  }
  
  def run do
    IO.puts("\n=== MEV Bundle Example ===\n")
    
    # Step 1: Create transactions
    IO.puts("1. Creating transactions...")
    transactions = create_sample_transactions()
    IO.puts("   Created #{length(transactions)} transactions")
    
    # Step 2: Create bundle
    IO.puts("\n2. Creating bundle...")
    {:ok, current_block} = Ethers.current_block_number(url: "http://localhost:8545")
    target_block = current_block + 1
    
    {:ok, bundle} = MEV.create_bundle(transactions, 
      block_number: target_block
    )
    IO.puts("   Bundle created for block #{target_block}")
    
    # Step 3: Add optional bundle parameters
    IO.puts("\n3. Configuring bundle...")
    bundle = bundle
      |> MEV.with_timestamp_range(nil, :os.system_time(:second) + 60)
      |> MEV.with_reverting_hashes(nil)
    
    IO.puts("   Added timestamp constraint (valid for 60 seconds)")
    
    # Step 4: Display bundle info
    IO.puts("\n4. Bundle details:")
    IO.puts("   Block target: #{bundle.block_number}")
    IO.puts("   Transactions: #{length(bundle.transactions)}")
    IO.puts("   Max timestamp: #{bundle.max_timestamp}")
    
    # Step 5: Simulate bundle (if provider available)
    IO.puts("\n5. Bundle simulation:")
    IO.puts("   Note: Actual simulation requires a configured MEV provider")
    IO.puts("   In production, you would use:")
    IO.puts("   {:ok, simulation} = MEV.simulate_bundle(bundle, provider: Flashbots, signer: signer)")
    
    # Step 6: Submit bundle (if provider available) 
    IO.puts("\n6. Bundle submission:")
    IO.puts("   Note: Actual submission requires a configured MEV provider")
    IO.puts("   In production, you would use:")
    IO.puts("   {:ok, bundle_hash} = MEV.send_bundle(bundle, provider: Flashbots, signer: signer)")
    
    # Step 7: Monitor bundle (demonstration)
    IO.puts("\n7. Bundle monitoring:")
    demonstrate_monitoring()
    
    IO.puts("\n=== Example Complete ===\n")
  end
  
  defp create_sample_transactions do
    # Create 3 sample transactions
    for nonce <- 0..2 do
      tx = %Transaction.Legacy{
        nonce: nonce,
        gas_price: 20_000_000_000 + (nonce * 1_000_000_000), # Increasing gas price
        gas: 21_000,
        to: @to_account.address,
        value: 1_000_000_000_000_000, # 0.001 ETH
        input: "",
        chain_id: 1
      }
      
      {:ok, signed} = Local.sign_transaction(tx, 
        private_key: @from_account.private_key,
        from: @from_account.address
      )
      
      signed
    end
  end
  
  defp demonstrate_monitoring do
    IO.puts("   Starting bundle monitor...")
    
    # Create a mock bundle hash
    bundle_hash = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    
    {:ok, current_block} = Ethers.current_block_number(url: "http://localhost:8545")
    
    # Start monitoring
    {:ok, monitor} = MEV.monitor_bundle(
      bundle_hash,
      current_block + 1,
      provider: Ethers.MEV.Providers.Flashbots,
      provider_opts: [url: "http://localhost:8545"],
      check_interval: 1000,
      max_wait: 3
    )
    
    IO.puts("   Monitor started (PID: #{inspect(monitor)})")
    IO.puts("   Waiting for 3 seconds...")
    Process.sleep(3000)
    
    # Stop monitor
    GenServer.stop(monitor, :normal)
    IO.puts("   Monitor stopped")
  end
  
  # Alternative: Pipeline-style bundle creation
  def pipeline_example do
    IO.puts("\n=== Pipeline Style Example ===\n")
    
    transactions = create_sample_transactions()
    {:ok, current_block} = Ethers.current_block_number(url: "http://localhost:8545")
    
    result = transactions
      |> MEV.bundle(block_number: current_block + 1)
      |> MEV.with_timestamp_range(nil, :os.system_time(:second) + 60)
      |> MEV.with_reverting_hashes(["0xabc123"])  # Allow specific tx to revert
      |> MEV.with_replacement_uuid(Utils.generate_uuid())
      |> inspect_bundle()
    
    IO.puts("Pipeline result: Bundle with #{length(result.transactions)} transactions")
  end
  
  defp inspect_bundle(bundle) do
    IO.puts("\nBundle inspection:")
    IO.puts("  Block: #{bundle.block_number}")
    IO.puts("  Transactions: #{length(bundle.transactions)}")
    IO.puts("  Reverting allowed: #{inspect(bundle.reverting_tx_hashes)}")
    IO.puts("  Replacement UUID: #{bundle.replacement_uuid}")
    bundle
  end
end

# Run the example
MEVBundleExample.run()
MEVBundleExample.pipeline_example()