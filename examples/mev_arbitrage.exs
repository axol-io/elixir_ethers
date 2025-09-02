#!/usr/bin/env elixir

# MEV Arbitrage Example
# 
# This example demonstrates how to use the Ethers MEV module to:
# 1. Monitor for arbitrage opportunities
# 2. Create and submit bundles to capture MEV
# 3. Handle retries and monitoring

Mix.install([
  {:ethers, path: ".."},
  {:req, "~> 0.4"},
  {:jason, "~> 1.4"}
])

defmodule ArbitrageBot do
  @moduledoc """
  Example arbitrage bot using Ethers MEV functionality.
  """
  
  alias Ethers.MEV
  alias Ethers.MEV.Bundle
  
  @dex_a "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"  # Uniswap V2 Router
  @dex_b "0xE592427A0AEce92De3Edee1F18E0157C05861564"  # Uniswap V3 Router
  @weth "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  @usdc "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  
  def run(opts \\ []) do
    # Configuration
    private_key = Keyword.fetch!(opts, :private_key)
    rpc_url = Keyword.get(opts, :rpc_url, "http://localhost:8545")
    
    # Start monitoring
    IO.puts("Starting arbitrage bot...")
    
    # Main loop
    Stream.interval(12_000)  # Every block (~12s)
    |> Stream.each(fn _ -> check_arbitrage_opportunity(private_key, rpc_url) end)
    |> Stream.run()
  end
  
  defp check_arbitrage_opportunity(private_key, rpc_url) do
    with {:ok, prices} <- fetch_prices(rpc_url),
         {:ok, opportunity} <- calculate_arbitrage(prices),
         true <- profitable?(opportunity),
         {:ok, bundle} <- create_arbitrage_bundle(opportunity, private_key),
         {:ok, result} <- submit_bundle(bundle, private_key, rpc_url) do
      
      IO.puts("Arbitrage executed: #{inspect(result)}")
      monitor_bundle(result.bundle_hash)
    else
      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
      
      false ->
        IO.puts("No profitable opportunity found")
      
      _ ->
        :ok
    end
  end
  
  defp fetch_prices(rpc_url) do
    # Fetch prices from DEXs
    # This would involve calling getAmountsOut on routers
    {:ok, %{
      dex_a: %{weth_usdc: 3000_000_000},  # $3000 per ETH
      dex_b: %{weth_usdc: 3010_000_000}   # $3010 per ETH
    }}
  end
  
  defp calculate_arbitrage(prices) do
    spread = prices.dex_b.weth_usdc - prices.dex_a.weth_usdc
    
    if spread > 0 do
      {:ok, %{
        buy_from: :dex_a,
        sell_to: :dex_b,
        spread: spread,
        amount: calculate_optimal_amount(spread)
      }}
    else
      {:ok, %{
        buy_from: :dex_b,
        sell_to: :dex_a,
        spread: abs(spread),
        amount: calculate_optimal_amount(abs(spread))
      }}
    end
  end
  
  defp calculate_optimal_amount(spread) do
    # Calculate optimal trade size based on spread
    # Simplified calculation
    min(1_000_000_000_000_000_000, spread * 100)  # Max 1 ETH
  end
  
  defp profitable?(%{spread: spread, amount: amount}) do
    expected_profit = (spread * amount) / 1_000_000
    gas_cost = 200_000 * 20_000_000_000  # 200k gas @ 20 gwei
    
    expected_profit > gas_cost * 2  # 2x gas cost minimum
  end
  
  defp create_arbitrage_bundle(opportunity, private_key) do
    {:ok, current_block} = Ethers.current_block_number()
    
    # Create swap transactions
    tx1 = create_swap_tx(
      opportunity.buy_from,
      @weth,
      @usdc,
      opportunity.amount,
      private_key
    )
    
    tx2 = create_swap_tx(
      opportunity.sell_to,
      @usdc,
      @weth,
      opportunity.amount,
      private_key
    )
    
    # Create bundle
    MEV.create_bundle([tx1, tx2], current_block + 1)
  end
  
  defp create_swap_tx(dex, token_in, token_out, amount, private_key) do
    # Build swap transaction
    # This would encode the actual swap call
    %{
      to: dex,
      data: encode_swap(token_in, token_out, amount),
      value: 0,
      gas: 200_000,
      gas_price: 20_000_000_000
    }
    |> sign_transaction(private_key)
  end
  
  defp encode_swap(_token_in, _token_out, _amount) do
    # Encode swap function call
    "0x..."
  end
  
  defp sign_transaction(tx_params, private_key) do
    # Sign transaction with private key
    {:ok, signed} = Ethers.Signer.Local.sign_transaction(
      tx_params,
      private_key: private_key
    )
    signed
  end
  
  defp submit_bundle(bundle, private_key, rpc_url) do
    # Use pipeline for submission
    result = bundle
    |> MEV.pipe_simulate(
      provider: Ethers.MEV.Providers.Flashbots,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: private_key],
      rpc_opts: [url: rpc_url]
    )
    |> MEV.pipe_submit_if_profitable(
      min_profit: 1_000_000_000_000_000  # 0.001 ETH minimum
    )
    
    case result do
      {:ok, hash} ->
        {:ok, %{bundle_hash: hash, bundle: bundle}}
      
      {:skip, reason} ->
        IO.puts("Bundle skipped: #{inspect(reason)}")
        {:error, :not_profitable}
      
      error ->
        error
    end
  end
  
  defp monitor_bundle(bundle_hash) do
    Task.async(fn ->
      case MEV.BundleMonitor.wait_for_inclusion(bundle_hash, timeout: 30_000) do
        {:ok, :included} ->
          IO.puts("Bundle #{bundle_hash} included!")
        
        {:ok, :not_included} ->
          IO.puts("Bundle #{bundle_hash} not included")
        
        {:error, reason} ->
          IO.puts("Monitor error: #{inspect(reason)}")
      end
    end)
  end
end

# Run the bot
# ArbitrageBot.run(private_key: System.get_env("PRIVATE_KEY"))