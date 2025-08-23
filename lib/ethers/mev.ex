defmodule Ethers.MEV do
  @moduledoc """
  High-level interface for MEV (Maximum Extractable Value) operations.

  This module provides a unified API for interacting with different MEV providers,
  creating and managing bundles, and submitting transactions through MEV relays.

  ## Architecture

  The module is organized into three main sections:

  1. **Bundle Management** - Creation and manipulation of bundles
  2. **Provider Operations** - Interaction with MEV providers (send, simulate, etc.)
  3. **Pipeline Helpers** - Functional composition utilities

  ## Overview

  MEV refers to the maximum value that can be extracted from block production in
  excess of the standard block reward and gas fees. This module enables:

  - Bundle creation and management
  - Transaction simulation before submission
  - Submission to MEV relays (Flashbots, Eden, etc.)
  - Bundle status monitoring

  ## Examples

      # Create a bundle
      {:ok, bundle} = Ethers.MEV.create_bundle(
        [signed_tx1, signed_tx2],
        block_number: 12345
      )
      
      # Simulate the bundle
      {:ok, simulation} = Ethers.MEV.simulate_bundle(bundle, 
        provider: Ethers.MEV.Flashbots,
        signer: signer
      )
      
      # Submit if profitable
      if simulation.profit > 0 do
        {:ok, bundle_hash} = Ethers.MEV.send_bundle(bundle,
          provider: Ethers.MEV.Flashbots,
          signer: signer
        )
      end
  """

  alias Ethers.MEV.Bundle
  alias Ethers.Transaction

  # Will be Ethers.MEV.Flashbots in Phase 2
  @default_provider nil

  # ============================================================================
  # Bundle Management
  # ============================================================================

  @doc """
  Creates a new bundle of transactions.

  ## Parameters
  - `transactions` - List of signed transactions (as Transaction structs or hex strings)
  - `opts` - Bundle options:
    - `:block_number` - Target block number (required)
    - `:min_timestamp` - Minimum Unix timestamp for inclusion
    - `:max_timestamp` - Maximum Unix timestamp for inclusion
    - `:reverting_tx_hashes` - Transaction hashes allowed to revert
    - `:replacement_uuid` - UUID for bundle replacement

  ## Examples

      iex> Ethers.MEV.create_bundle([tx1, tx2], block_number: 12345)
      {:ok, %Bundle{...}}
      
      iex> Ethers.MEV.create_bundle([], block_number: 12345)
      {:error, :empty_bundle}
  """
  @spec create_bundle([Transaction.t() | String.t()], keyword()) ::
          {:ok, Bundle.t()} | {:error, term()}
  def create_bundle(transactions, opts \\ []) do
    case Keyword.fetch(opts, :block_number) do
      {:ok, block_number} ->
        Bundle.new(build_bundle_params(transactions, block_number, opts))

      :error ->
        {:error, :missing_block_number}
    end
  end

  @doc """
  Creates a new bundle, raising on error.

  ## Examples

      iex> Ethers.MEV.create_bundle!([tx1, tx2], block_number: 12345)
      %Bundle{...}
  """
  @spec create_bundle!([Transaction.t() | String.t()], keyword()) :: Bundle.t()
  def create_bundle!(transactions, opts \\ []) do
    case create_bundle(transactions, opts) do
      {:ok, bundle} -> bundle
      {:error, reason} -> raise ArgumentError, format_error_message(:bundle_creation, reason)
    end
  end

  # ============================================================================
  # Provider Operations
  # ============================================================================

  @doc """
  Sends a bundle to the specified MEV provider.

  ## Parameters
  - `bundle` - The bundle to send
  - `opts` - Options:
    - `:provider` - MEV provider module (defaults to configured provider)
    - `:signer` - Signer for authentication
    - Other provider-specific options

  ## Returns
  - `{:ok, bundle_hash}` - Hash identifying the submitted bundle
  - `{:error, reason}` - Error if submission fails

  ## Examples

      iex> bundle = Ethers.MEV.create_bundle!([tx1, tx2], block_number: 12345)
      iex> Ethers.MEV.send_bundle(bundle, 
      ...>   provider: Ethers.MEV.Flashbots,
      ...>   signer: {Ethers.Signer.Local, private_key: key}
      ...> )
      {:ok, "0xbundle_hash..."}
  """
  @spec send_bundle(Bundle.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_bundle(%Bundle{} = bundle, opts \\ []) do
    with_provider(opts, fn provider ->
      provider.send_bundle(bundle, opts)
    end)
  end

  @doc """
  Simulates a bundle execution without sending it to miners.

  ## Parameters
  - `bundle` - The bundle to simulate
  - `opts` - Options:
    - `:provider` - MEV provider module
    - `:signer` - Signer for authentication
    - Other provider-specific options

  ## Returns
  - `{:ok, simulation_result}` - Simulation details including gas usage and profit
  - `{:error, reason}` - Error if simulation fails

  ## Examples

      iex> Ethers.MEV.simulate_bundle(bundle,
      ...>   provider: Ethers.MEV.Flashbots,
      ...>   signer: signer
      ...> )
      {:ok, %{results: [...], totalGasUsed: 150000}}
  """
  @spec simulate_bundle(Bundle.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def simulate_bundle(%Bundle{} = bundle, opts \\ []) do
    with_provider(opts, fn provider ->
      provider.simulate_bundle(bundle, opts)
    end)
  end

  @doc """
  Gets the status of a previously submitted bundle.

  ## Parameters
  - `bundle_hash` - Hash returned from send_bundle
  - `block_number` - Block number to check status for
  - `opts` - Provider options

  ## Returns
  - `{:ok, status}` - Bundle status information
  - `{:error, reason}` - Error if status check fails
  """
  @spec get_bundle_status(String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_bundle_status(bundle_hash, block_number, opts \\ []) do
    with_provider(opts, fn provider ->
      provider.get_bundle_status(bundle_hash, block_number, opts)
    end)
  end

  @doc """
  Cancels a pending bundle.

  ## Parameters
  - `bundle_hash` - Hash of the bundle to cancel
  - `opts` - Provider options

  ## Returns
  - `{:ok, :cancelled}` - Bundle successfully cancelled
  - `{:error, reason}` - Error if cancellation fails
  """
  @spec cancel_bundle(String.t(), keyword()) :: {:ok, :cancelled} | {:error, term()}
  def cancel_bundle(bundle_hash, opts \\ []) do
    with_provider(opts, fn provider ->
      provider.cancel_bundle(bundle_hash, opts)
    end)
  end

  # ============================================================================
  # Pipeline Helpers (Functional Composition)
  # ============================================================================

  @doc """
  Creates a bundle from a list of transactions (pipeline-friendly).

  Raises on error to support pipeline composition.

  ## Examples

      [tx1, tx2, tx3]
      |> Ethers.MEV.bundle(block_number: 12345)
      |> Ethers.MEV.with_reverting_hashes(["0x..."])
      |> Ethers.MEV.simulate(signer: signer)
  """
  @spec bundle([Transaction.t() | String.t()], keyword()) :: Bundle.t()
  def bundle(transactions, opts) do
    create_bundle!(transactions, opts)
  end

  @doc """
  Adds reverting transaction hashes to a bundle (pipeline-friendly).

  ## Examples

      bundle
      |> Ethers.MEV.with_reverting_hashes(["0xabc...", "0xdef..."])
      |> Ethers.MEV.send(signer: signer)
  """
  @spec with_reverting_hashes(Bundle.t(), [String.t()] | nil) :: Bundle.t()
  defdelegate with_reverting_hashes(bundle, hashes), to: Bundle, as: :allow_reverts

  @doc """
  Sets timestamp constraints on a bundle (pipeline-friendly).

  ## Examples

      bundle
      |> Ethers.MEV.with_timestamp_range(min_time, max_time)
      |> Ethers.MEV.send(signer: signer)
  """
  @spec with_timestamp_range(Bundle.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          Bundle.t()
  defdelegate with_timestamp_range(bundle, min, max), to: Bundle, as: :set_timing_constraints

  @doc """
  Sets a replacement UUID on a bundle (pipeline-friendly).

  ## Examples

      bundle
      |> Ethers.MEV.with_replacement_uuid(uuid)
      |> Ethers.MEV.send(signer: signer)
  """
  @spec with_replacement_uuid(Bundle.t(), String.t() | nil) :: Bundle.t()
  defdelegate with_replacement_uuid(bundle, uuid), to: Bundle, as: :set_replacement_uuid

  @doc """
  Simulates a bundle (pipeline-friendly).

  Returns the simulation result or raises on error.

  ## Examples

      bundle
      |> Ethers.MEV.simulate(signer: signer)
      |> Map.get(:results)
      |> process_results()
  """
  @spec simulate(Bundle.t(), keyword()) :: map()
  def simulate(%Bundle{} = bundle, opts) do
    case simulate_bundle(bundle, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise format_error_message(:simulation, reason)
    end
  end

  @doc """
  Sends a bundle (pipeline-friendly).

  Returns the bundle hash or raises on error.

  ## Examples

      bundle
      |> Ethers.MEV.send(signer: signer)
      |> IO.puts()
  """
  @spec send(Bundle.t(), keyword()) :: String.t()
  def send(%Bundle{} = bundle, opts) do
    case send_bundle(bundle, opts) do
      {:ok, hash} -> hash
      {:error, reason} -> raise format_error_message(:submission, reason)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp with_provider(opts, callback) do
    case get_provider(opts) do
      nil -> {:error, :no_provider_configured}
      provider -> callback.(provider)
    end
  end

  defp get_provider(opts) do
    Keyword.get(opts, :provider) || get_default_provider()
  end

  defp get_default_provider do
    Application.get_env(:ethers, :default_mev_provider, @default_provider)
  end

  defp build_bundle_params(transactions, block_number, opts) do
    %{
      transactions: transactions,
      block_number: block_number,
      min_timestamp: opts[:min_timestamp],
      max_timestamp: opts[:max_timestamp],
      reverting_tx_hashes: opts[:reverting_tx_hashes],
      replacement_uuid: opts[:replacement_uuid]
    }
  end

  defp format_error_message(operation, reason) do
    "#{format_operation(operation)} failed: #{inspect(reason)}"
  end

  defp format_operation(:bundle_creation), do: "Bundle creation"
  defp format_operation(:simulation), do: "Simulation"
  defp format_operation(:submission), do: "Bundle submission"
  defp format_operation(op), do: to_string(op)
end
