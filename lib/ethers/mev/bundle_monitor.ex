defmodule Ethers.MEV.BundleMonitor do
  @moduledoc """
  Monitors bundle inclusion and provides utilities for tracking bundle status.

  This module implements patterns similar to the TypeScript client's
  `waitForBundleInclusion` functionality, allowing you to monitor whether
  a bundle has been included in a block.

  ## Example

      {:ok, monitor} = BundleMonitor.start_link(
        bundle_hash: "0x...",
        target_block: 12345678,
        provider: Ethers.MEV.Providers.Flashbots,
        provider_opts: [...]
      )

      case BundleMonitor.wait_for_inclusion(monitor, timeout: 60_000) do
        {:ok, :included} -> IO.puts("Bundle included!")
        {:ok, :not_included} -> IO.puts("Bundle not included in target block")
        {:error, :timeout} -> IO.puts("Timed out waiting for inclusion")
      end
  """

  use GenServer
  require Logger

  alias Ethers.Utils

  @type status :: :pending | :included | :not_included | :failed
  @type monitor_state :: %{
          bundle_hash: String.t(),
          target_block: non_neg_integer(),
          status: status(),
          provider: module(),
          provider_opts: keyword(),
          check_interval: non_neg_integer(),
          max_block_wait: non_neg_integer(),
          subscribers: list(GenServer.from()),
          transaction_hashes: list(String.t()) | nil
        }

  # Default check interval in milliseconds
  @default_check_interval 2_000
  # Default max blocks to wait past target
  @default_max_block_wait 5

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a bundle monitor process.

  ## Options
  - `:bundle_hash` - The bundle hash to monitor (required)
  - `:target_block` - The target block number (required)
  - `:provider` - The MEV provider module (required)
  - `:provider_opts` - Options for the provider (required)
  - `:check_interval` - Interval between checks in ms (default: 2000)
  - `:max_block_wait` - Max blocks to wait past target (default: 5)
  - `:name` - Optional process name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Waits for bundle inclusion with a timeout.

  ## Options
  - `:timeout` - Maximum time to wait in milliseconds (default: 30000)

  ## Returns
  - `{:ok, :included}` - Bundle was included
  - `{:ok, :not_included}` - Bundle was not included in target block
  - `{:error, :timeout}` - Timed out waiting
  - `{:error, reason}` - Other error
  """
  @spec wait_for_inclusion(GenServer.server(), keyword()) ::
          {:ok, :included | :not_included} | {:error, term()}
  def wait_for_inclusion(monitor, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    try do
      GenServer.call(monitor, :wait_for_inclusion, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Gets the current status of the monitored bundle.
  """
  @spec get_status(GenServer.server()) :: {:ok, status()} | {:error, term()}
  def get_status(monitor) do
    GenServer.call(monitor, :get_status)
  end

  @doc """
  Stops monitoring the bundle.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(monitor) do
    GenServer.stop(monitor)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    case validate_and_build_state(opts) do
      {:ok, state} ->
        # Start monitoring immediately
        send(self(), :check_bundle)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:wait_for_inclusion, from, state) do
    case state.status do
      :pending ->
        # Add caller to subscribers
        {:noreply, %{state | subscribers: [from | state.subscribers]}}

      status ->
        # Already have a result
        {:reply, format_status_result(status), state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_info(:check_bundle, state) do
    case check_bundle_status(state) do
      {:ok, :pending} ->
        # Still pending, schedule next check
        Process.send_after(self(), :check_bundle, state.check_interval)
        {:noreply, state}

      {:ok, new_status} ->
        # Status changed, notify subscribers
        new_state = %{state | status: new_status}
        notify_subscribers(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Bundle monitor check failed: #{inspect(reason)}")
        new_state = %{state | status: :failed}
        notify_subscribers(new_state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:check_block_number, state) do
    case get_current_block(state) do
      {:ok, current_block} when current_block > state.target_block + state.max_block_wait ->
        # Passed target block + buffer, bundle not included
        new_state = %{state | status: :not_included}
        notify_subscribers(new_state)
        {:noreply, new_state}

      {:ok, _current_block} ->
        # Still within range, continue monitoring
        Process.send_after(self(), :check_block_number, state.check_interval)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to get block number: #{inspect(reason)}")
        Process.send_after(self(), :check_block_number, state.check_interval)
        {:noreply, state}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp validate_and_build_state(opts) do
    with {:ok, bundle_hash} <- fetch_required(opts, :bundle_hash),
         {:ok, target_block} <- fetch_required(opts, :target_block),
         {:ok, provider} <- fetch_required(opts, :provider),
         {:ok, provider_opts} <- fetch_required(opts, :provider_opts) do
      state = %{
        bundle_hash: bundle_hash,
        target_block: target_block,
        status: :pending,
        provider: provider,
        provider_opts: provider_opts,
        check_interval: Keyword.get(opts, :check_interval, @default_check_interval),
        max_block_wait: Keyword.get(opts, :max_block_wait, @default_max_block_wait),
        subscribers: [],
        transaction_hashes: Keyword.get(opts, :transaction_hashes)
      }

      {:ok, state}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_option, key}}
    end
  end

  defp check_bundle_status(state) do
    case state.provider.get_bundle_status(
           state.bundle_hash,
           state.target_block,
           state.provider_opts
         ) do
      {:ok, %{is_sent_to_miners: true}} ->
        # Bundle was sent to miners, check if block has passed
        check_if_block_passed(state)

      {:ok, %{is_simulated: true, is_sent_to_miners: false}} ->
        # Only simulated, not sent
        {:ok, :pending}

      {:ok, _} ->
        # Unknown status, keep checking
        {:ok, :pending}

      {:error, :bundle_not_found} ->
        # Bundle doesn't exist
        {:ok, :not_included}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_if_block_passed(state) do
    case get_current_block(state) do
      {:ok, current_block} when current_block >= state.target_block ->
        # Target block has been mined, check if bundle was included
        check_bundle_in_block(state)

      {:ok, _} ->
        # Target block not yet mined
        {:ok, :pending}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_bundle_in_block(state) do
    # Check if the bundle transactions appear in the target block
    check_transactions_in_block(state)
  end

  defp check_transactions_in_block(state) do
    # Fetch the block with full transaction details
    block_hex = Utils.integer_to_hex(state.target_block)

    case Ethereumex.HttpClient.eth_get_block_by_number(block_hex, true, state.provider_opts) do
      {:ok, nil} ->
        # Block doesn't exist yet
        {:ok, :pending}

      {:ok, block} ->
        # Get transaction hashes from the block
        block_tx_hashes =
          block
          |> Map.get("transactions", [])
          |> Enum.map(fn
            tx when is_map(tx) -> Map.get(tx, "hash")
            hash when is_binary(hash) -> hash
          end)
          |> MapSet.new()

        # Check if all bundle transactions are in the block
        # Note: We need the bundle transaction hashes from the state
        # For now, we check using the bundle_hash as a proxy
        if bundle_included?(state.bundle_hash, block_tx_hashes, state) do
          {:ok, :included}
        else
          {:ok, :not_included}
        end

      {:error, reason} ->
        {:error, {:block_fetch_failed, reason}}
    end
  end

  defp bundle_included?(_bundle_hash, block_tx_hashes, state) do
    case state.transaction_hashes do
      nil ->
        # No transaction hashes provided, use provider-specific check
        # This would call the provider's bundle status API
        check_with_provider(state)

      tx_hashes when is_list(tx_hashes) ->
        # Check if all bundle transactions are in the block
        Enum.all?(tx_hashes, fn hash ->
          MapSet.member?(block_tx_hashes, normalize_hash(hash))
        end)
    end
  end

  defp check_with_provider(_state) do
    # Use provider's bundle status API if available
    # For now, return false as we need the actual transaction hashes
    Logger.debug("No transaction hashes provided for bundle monitoring, using fallback")
    false
  end

  defp normalize_hash("0x" <> _ = hash), do: String.downcase(hash)
  defp normalize_hash(hash), do: "0x" <> String.downcase(hash)

  defp get_current_block(state) do
    # Use Ethers to get current block number
    case Ethers.current_block_number(state.provider_opts) do
      {:ok, block_number} -> {:ok, block_number}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_subscribers(state) do
    result = format_status_result(state.status)

    Enum.each(state.subscribers, fn from ->
      GenServer.reply(from, result)
    end)
  end

  defp format_status_result(:included), do: {:ok, :included}
  defp format_status_result(:not_included), do: {:ok, :not_included}
  defp format_status_result(:failed), do: {:error, :monitoring_failed}
  defp format_status_result(:pending), do: {:ok, :pending}
end
