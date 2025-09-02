#!/usr/bin/env elixir

# MEV Sandwich Protection Example
# 
# This example demonstrates how to:
# 1. Detect potential sandwich attacks
# 2. Submit transactions through private mempools
# 3. Use MEV bundles for protection

Mix.install([
  {:ethers, path: ".."},
  {:req, "~> 0.4"},
  {:jason, "~> 1.4"}
])

defmodule SandwichProtection do
  @moduledoc """
  Example of protecting transactions from sandwich attacks using MEV.
  """
  
  alias Ethers.MEV
  alias Ethers.MEV.Bundle
  
  def protect_swap(swap_params, opts \\ []) do
    private_key = Keyword.fetch!(opts, :private_key)
    rpc_url = Keyword.get(opts, :rpc_url, "http://localhost:8545")
    
    IO.puts("Protecting swap from sandwich attacks...")
    
    # Strategy 1: Use private mempool
    case submit_private(swap_params, private_key, rpc_url) do
      {:ok, result} ->
        IO.puts("Transaction submitted privately: #{result}")
        {:ok, result}
      
      {:error, _} ->
        # Fallback to Strategy 2: Bundle with protection
        submit_protected_bundle(swap_params, private_key, rpc_url)
    end
  end
  
  def detect_sandwich_risk(tx_params, rpc_url) do
    # Analyze transaction for sandwich risk
    risk_factors = [
      large_swap?: is_large_swap?(tx_params),
      high_slippage?: has_high_slippage?(tx_params),
      popular_pool?: is_popular_pool?(tx_params),
      mempool_congestion?: check_mempool_congestion(rpc_url)
    ]
    
    risk_score = Enum.count(risk_factors, fn {_, v} -> v end)
    
    %{
      risk_level: categorize_risk(risk_score),
      risk_score: risk_score,
      factors: risk_factors,
      recommendation: recommend_protection(risk_score)
    }
  end
  
  defp submit_private(swap_params, private_key, rpc_url) do
    # Create and sign transaction
    tx = create_transaction(swap_params, private_key)
    
    # Submit through Flashbots Protect
    Ethers.MEV.Providers.Flashbots.send_private_transaction(
      tx,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: private_key],
      rpc_opts: [url: rpc_url],
      fast: true  # Use fast mode for quicker inclusion
    )
  end
  
  defp submit_protected_bundle(swap_params, private_key, rpc_url) do
    {:ok, current_block} = Ethers.current_block_number([url: rpc_url])
    
    # Create main swap transaction
    swap_tx = create_transaction(swap_params, private_key)
    
    # Create protection transactions (dummy txs to fill block space)
    protection_txs = create_protection_transactions(private_key)
    
    # Bundle with protection
    transactions = [
      Enum.at(protection_txs, 0),  # Pre-transaction
      swap_tx,                      # Main swap
      Enum.at(protection_txs, 1)   # Post-transaction
    ]
    
    {:ok, bundle} = MEV.create_bundle(transactions, current_block + 1)
    
    # Submit bundle
    bundle
    |> MEV.pipe_simulate(
      provider: Ethers.MEV.Providers.Flashbots,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: private_key],
      rpc_opts: [url: rpc_url]
    )
    |> MEV.pipe_submit(
      provider: Ethers.MEV.Providers.Flashbots,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: private_key]
    )
  end
  
  defp create_transaction(params, private_key) do
    tx_data = %{
      to: params.to,
      data: params.data,
      value: params.value || 0,
      gas: params.gas || 300_000,
      gas_price: params.gas_price || 30_000_000_000,
      nonce: get_nonce(params.from)
    }
    
    {:ok, signed} = Ethers.Signer.Local.sign_transaction(
      tx_data,
      private_key: private_key,
      from: params.from
    )
    
    signed
  end
  
  defp create_protection_transactions(private_key) do
    # Create dummy transactions to protect the main swap
    # These consume block space making sandwich attacks less profitable
    
    from = derive_address(private_key)
    
    for i <- 0..1 do
      create_transaction(
        %{
          from: from,
          to: from,  # Self-transfer
          value: 0,
          data: "",
          gas: 21_000,
          gas_price: 35_000_000_000  # Higher gas to ensure inclusion
        },
        private_key
      )
    end
  end
  
  defp is_large_swap?(tx_params) do
    # Check if swap amount is large (> 10 ETH equivalent)
    tx_params[:value] && tx_params.value > 10_000_000_000_000_000_000
  end
  
  defp has_high_slippage?(tx_params) do
    # Decode swap data to check slippage tolerance
    # Simplified check
    true
  end
  
  defp is_popular_pool?(tx_params) do
    # Check if targeting popular pools (WETH/USDC, etc.)
    popular_pools = [
      "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",  # Uniswap V3 WETH/USDC
      "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8"   # Uniswap V3 WETH/USDT
    ]
    
    tx_params.to in popular_pools
  end
  
  defp check_mempool_congestion(rpc_url) do
    # Check current gas prices as proxy for congestion
    case Ethers.gas_price([url: rpc_url]) do
      {:ok, gas_price} ->
        gas_price > 50_000_000_000  # > 50 gwei indicates congestion
      
      _ ->
        false
    end
  end
  
  defp categorize_risk(score) when score >= 3, do: :high
  defp categorize_risk(score) when score >= 2, do: :medium
  defp categorize_risk(_), do: :low
  
  defp recommend_protection(score) when score >= 3 do
    "Use private mempool or bundle protection"
  end
  
  defp recommend_protection(score) when score >= 2 do
    "Consider using private mempool"
  end
  
  defp recommend_protection(_) do
    "Standard transaction should be safe"
  end
  
  defp get_nonce(address) do
    {:ok, nonce} = Ethers.get_transaction_count(address)
    nonce
  end
  
  defp derive_address(private_key) do
    # Derive address from private key
    {:ok, address} = Ethers.Signer.Local.get_address(private_key: private_key)
    address
  end
end

# Example usage
swap_params = %{
  from: "0xYourAddress",
  to: "0xUniswapRouter",
  data: "0x...",  # Encoded swap call
  value: 1_000_000_000_000_000_000,  # 1 ETH
  gas: 300_000
}

# Check risk
risk = SandwichProtection.detect_sandwich_risk(swap_params, "http://localhost:8545")
IO.inspect(risk, label: "Sandwich Risk Analysis")

# Protect swap if needed
if risk.risk_level == :high do
  SandwichProtection.protect_swap(
    swap_params,
    private_key: System.get_env("PRIVATE_KEY")
  )
end