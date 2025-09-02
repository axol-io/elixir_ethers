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
  alias Ethers.MEV.BundleMonitor
  alias Ethers.MEV.ConflictDetector
  alias Ethers.MEV.Utils
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
  # Advanced Features
  # ============================================================================

  @doc """
  Replaces a previously submitted bundle with a new one.

  Uses the same replacement UUID to override the previous bundle.
  The new bundle must target the same or later block.

  ## Parameters
  - `original_bundle_hash` - Hash of the bundle to replace
  - `new_bundle` - The replacement bundle
  - `opts` - Provider options

  ## Example

      {:ok, original_hash} = Ethers.MEV.send_bundle(bundle, opts)

      # Later, replace it with higher gas price
      new_bundle = bundle
        |> Bundle.set_replacement_uuid(UUID.generate())
        |> update_gas_prices()

      {:ok, new_hash} = Ethers.MEV.replace_bundle(
        original_hash,
        new_bundle,
        opts
      )
  """
  @spec replace_bundle(String.t(), Bundle.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def replace_bundle(_original_bundle_hash, %Bundle{} = new_bundle, opts \\ []) do
    # Ensure the new bundle has a replacement UUID
    if new_bundle.replacement_uuid do
      send_bundle(new_bundle, opts)
    else
      # Generate and set a replacement UUID
      uuid = generate_replacement_uuid()
      updated_bundle = Bundle.set_replacement_uuid(new_bundle, uuid)
      send_bundle(updated_bundle, opts)
    end
  end

  @doc """
  Monitors a bundle for inclusion with automatic status updates.

  Returns a monitor process that tracks the bundle status.

  ## Options
  - `:check_interval` - How often to check status (ms, default: 2000)
  - `:max_wait` - Maximum blocks to wait past target (default: 5)
  - `:timeout` - Total timeout for monitoring (ms, default: 60000)

  ## Example

      {:ok, hash} = Ethers.MEV.send_bundle(bundle, opts)
      {:ok, monitor} = Ethers.MEV.monitor_bundle(
        hash,
        bundle.block_number,
        opts
      )

      case BundleMonitor.wait_for_inclusion(monitor) do
        {:ok, :included} -> IO.puts("Success!")
        {:ok, :not_included} -> IO.puts("Not included")
        {:error, :timeout} -> IO.puts("Timed out")
      end
  """
  @spec monitor_bundle(String.t(), non_neg_integer(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def monitor_bundle(bundle_hash, target_block, opts \\ []) do
    monitor_opts =
      [
        bundle_hash: bundle_hash,
        target_block: target_block,
        provider: get_provider(opts),
        provider_opts: Keyword.get(opts, :provider_opts, [])
      ]
      |> Keyword.merge(Keyword.take(opts, [:check_interval, :max_wait]))

    BundleMonitor.start_link(monitor_opts)
  end

  @doc """
  Checks for conflicts before sending a bundle.

  Analyzes the bundle for potential conflicts that could prevent inclusion.

  ## Options
  - `:check_mempool` - Check against mempool (default: true)
  - `:check_balance` - Verify balances (default: true)
  - `:auto_resolve` - Attempt automatic resolution (default: false)

  ## Example

      case Ethers.MEV.check_and_send(bundle, opts) do
        {:ok, hash} ->
          IO.puts("Bundle sent: " <> hash)
        {:error, {:conflicts, conflicts}} ->
          IO.inspect(conflicts, label: "Conflicts detected")
        {:error, reason} ->
          IO.puts("Error: " <> inspect(reason))
      end
  """
  @spec check_and_send(Bundle.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def check_and_send(%Bundle{} = bundle, opts \\ []) do
    conflict_opts = Keyword.take(opts, [:check_mempool, :check_balance, :rpc_opts])

    case ConflictDetector.check_conflicts(bundle, conflict_opts) do
      {:ok, :no_conflicts} ->
        send_bundle(bundle, opts)

      {:ok, conflicts} ->
        if Keyword.get(opts, :auto_resolve, false) do
          attempt_auto_resolution(bundle, conflicts, opts)
        else
          {:error, {:conflicts_detected, conflicts}}
        end

      {:error, reason} ->
        {:error, {:conflict_check_failed, reason}}
    end
  end

  @doc """
  Simulates a bundle and only sends if profitable.

  ## Options
  - `:min_profit` - Minimum profit in wei (default: 0)
  - `:profit_margin` - Minimum profit margin as multiplier (e.g., 1.5 for 50% margin)

  ## Example

      Ethers.MEV.send_if_profitable(bundle,
        min_profit: 1_000_000_000_000_000,  # 0.001 ETH
        profit_margin: 1.2,  # 20% margin
        opts
      )
  """
  @spec send_if_profitable(Bundle.t(), keyword()) ::
          {:ok, String.t()} | {:skip, map()} | {:error, term()}
  def send_if_profitable(%Bundle{} = bundle, opts \\ []) do
    min_profit = Keyword.get(opts, :min_profit, 0)
    profit_margin = Keyword.get(opts, :profit_margin, 1.0)

    case simulate_bundle(bundle, opts) do
      {:ok, simulation} ->
        profit = calculate_profit(simulation)
        cost = Map.get(simulation, :total_gas_used, 0)

        cond do
          profit < min_profit ->
            {:skip, %{reason: :insufficient_profit, profit: profit, min_required: min_profit}}

          profit_margin > 1.0 and profit < cost * profit_margin ->
            {:skip,
             %{reason: :insufficient_margin, profit: profit, cost: cost, margin: profit / cost}}

          true ->
            send_bundle(bundle, opts)
        end

      error ->
        error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp generate_replacement_uuid do
    Utils.generate_uuid()
  end

  defp attempt_auto_resolution(_bundle, conflicts, _opts) do
    resolutions = ConflictDetector.suggest_resolutions(conflicts)

    # For now, we don't auto-resolve
    # This could be extended to handle simple cases like nonce updates
    {:error, {:conflicts_need_manual_resolution, resolutions}}
  end

  defp calculate_profit(simulation) do
    coinbase_diff = Map.get(simulation, :coinbase_diff, "0")

    case parse_hex_value(coinbase_diff) do
      {:ok, value} -> value
      _ -> 0
    end
  end

  defp parse_hex_value("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_hex}
    end
  end

  defp parse_hex_value(value) when is_integer(value), do: {:ok, value}
  defp parse_hex_value(_), do: {:error, :invalid_value}

  # ============================================================================
  # Private Helpers (continued from original)
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

  # ============================================================================
  # Pipeline & Functional Interface (Phase 7)
  # ============================================================================

  @doc """
  Creates a bundle from a list of transactions in a pipeline-friendly way.

  ## Example

      [tx1, tx2, tx3]
      |> Ethers.MEV.pipe_bundle(block_number: 12345)
      |> Ethers.MEV.with_timing(min: 1000, max: 2000)
      |> Ethers.MEV.pipe_simulate()
  """
  @spec pipe_bundle([Transaction.t()], keyword()) :: Bundle.t()
  def pipe_bundle(transactions, opts \\ []) when is_list(transactions) do
    block_number = Keyword.get(opts, :block_number) || get_next_block()

    case Bundle.new(%{
           transactions: transactions,
           block_number: block_number,
           min_timestamp: opts[:min_timestamp],
           max_timestamp: opts[:max_timestamp]
         }) do
      {:ok, bundle} -> bundle
      {:error, reason} -> raise "Failed to create bundle: #{inspect(reason)}"
    end
  end

  @doc """
  Adds timing constraints to a bundle.

  ## Example

      bundle
      |> Ethers.MEV.with_timing(min: 1000, max: 2000)
  """
  @spec with_timing(Bundle.t(), keyword()) :: Bundle.t()
  def with_timing(%Bundle{} = bundle, opts) do
    min_timestamp = Keyword.get(opts, :min)
    max_timestamp = Keyword.get(opts, :max)

    bundle
    |> then(fn b ->
      if min_timestamp,
        do: Bundle.set_timing_constraints(b, min_timestamp, b.max_timestamp || nil),
        else: b
    end)
    |> then(fn b ->
      if max_timestamp,
        do: Bundle.set_timing_constraints(b, b.min_timestamp || nil, max_timestamp),
        else: b
    end)
  end

  @doc """
  Adds reverting transaction allowance to a bundle.

  ## Example

      bundle
      |> Ethers.MEV.with_reverting_txs(["0xabc", "0xdef"])
  """
  @spec with_reverting_txs(Bundle.t(), [String.t()]) :: Bundle.t()
  def with_reverting_txs(%Bundle{} = bundle, tx_hashes) when is_list(tx_hashes) do
    Bundle.allow_reverts(bundle, tx_hashes)
  end

  @doc """
  Simulates a bundle and returns the result in a pipeline-friendly way.

  Returns the bundle with simulation results attached as metadata.

  ## Example

      bundle
      |> Ethers.MEV.pipe_simulate()
      |> Ethers.MEV.pipe_submit_if_profitable()
  """
  @spec pipe_simulate(Bundle.t(), keyword()) :: Bundle.t()
  def pipe_simulate(%Bundle{} = bundle, opts \\ []) do
    case simulate_bundle(bundle, opts) do
      {:ok, simulation} ->
        # Attach simulation results as metadata
        Map.put(bundle, :simulation, simulation)

      {:error, reason} ->
        raise "Simulation failed: #{inspect(reason)}"
    end
  end

  @doc """
  Submits a bundle only if it's profitable based on simulation.

  ## Example

      bundle
      |> Ethers.MEV.pipe_simulate()
      |> Ethers.MEV.pipe_submit_if_profitable(min_profit: 1000000)
  """
  @spec pipe_submit_if_profitable(map(), keyword()) :: {:ok, String.t()} | {:skip, map()}
  def pipe_submit_if_profitable(bundle, opts \\ [])

  def pipe_submit_if_profitable(%{simulation: simulation} = bundle, opts) do
    min_profit = Keyword.get(opts, :min_profit, 0)
    profit = calculate_profit(simulation)

    if profit >= min_profit do
      # Extract the Bundle struct - remove simulation field
      actual_bundle =
        bundle
        |> Map.delete(:simulation)
        |> then(fn b -> struct!(Bundle, Map.from_struct(b)) end)

      case send_bundle(actual_bundle, opts) do
        {:ok, hash} -> {:ok, hash}
        error -> error
      end
    else
      {:skip, %{reason: :insufficient_profit, profit: profit, required: min_profit}}
    end
  end

  def pipe_submit_if_profitable(%Bundle{} = bundle, opts) do
    # No simulation attached, run it first
    bundle
    |> pipe_simulate(opts)
    |> pipe_submit_if_profitable(opts)
  end

  @doc """
  Submits a bundle in a pipeline.

  ## Example

      bundle
      |> Ethers.MEV.pipe_submit()
  """
  @spec pipe_submit(Bundle.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def pipe_submit(%Bundle{} = bundle, opts \\ []) do
    send_bundle(bundle, opts)
  end

  defp get_next_block do
    case Ethers.current_block_number() do
      {:ok, current} -> current + 1
      _ -> raise "Failed to get current block number"
    end
  end
end
