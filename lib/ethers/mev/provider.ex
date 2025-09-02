defmodule Ethers.MEV.Provider do
  @moduledoc """
  Behaviour for MEV (Maximum Extractable Value) providers.

  This behaviour defines the interface that all MEV providers (Flashbots, Eden, etc.)
  must implement. It provides a consistent API for bundle submission, simulation,
  and monitoring across different MEV relay services.
  """

  alias Ethers.MEV.Bundle

  @type provider_opts :: keyword()
  @type bundle_hash :: String.t()
  @type block_number :: non_neg_integer()

  @doc """
  Sends a bundle of transactions to the MEV provider.

  ## Parameters
  - `bundle` - The bundle to submit
  - `opts` - Provider-specific options (e.g., signer, network, relay URL)

  ## Returns
  - `{:ok, bundle_hash}` - The hash identifying the submitted bundle
  - `{:error, reason}` - Error if submission fails
  """
  @callback send_bundle(Bundle.t(), provider_opts()) ::
              {:ok, bundle_hash()} | {:error, term()}

  @doc """
  Simulates a bundle execution without sending it to miners.

  This allows testing bundle profitability and checking for reverts
  before actual submission.

  ## Parameters
  - `bundle` - The bundle to simulate
  - `opts` - Provider-specific options

  ## Returns
  - `{:ok, simulation_result}` - Map containing simulation details
  - `{:error, reason}` - Error if simulation fails
  """
  @callback simulate_bundle(Bundle.t(), provider_opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Gets the status of a previously submitted bundle.

  ## Parameters
  - `bundle_hash` - The hash returned from send_bundle
  - `block_number` - The block number to check status for
  - `opts` - Provider-specific options

  ## Returns
  - `{:ok, status_map}` - Bundle status information
  - `{:error, reason}` - Error if status check fails
  """
  @callback get_bundle_status(bundle_hash(), block_number(), provider_opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Cancels a pending bundle that hasn't been included yet.

  ## Parameters
  - `bundle_hash` - The hash of the bundle to cancel
  - `opts` - Provider-specific options

  ## Returns
  - `{:ok, :cancelled}` - Bundle successfully cancelled
  - `{:error, reason}` - Error if cancellation fails
  """
  @callback cancel_bundle(bundle_hash(), provider_opts()) ::
              {:ok, :cancelled} | {:error, term()}

  @doc """
  Gets user statistics from the MEV provider.

  ## Parameters
  - `address` - The address to get statistics for
  - `opts` - Provider-specific options

  ## Returns
  - `{:ok, stats_map}` - User statistics
  - `{:error, reason}` - Error if request fails
  """
  @callback get_user_stats(Ethers.Types.t_address(), provider_opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Validates that required options are present for the provider.

  This is a helper function that providers can use to validate their options.
  """
  @spec validate_required_opts(keyword(), [atom()]) ::
          :ok | {:error, {:missing_required_opts, [atom()]}}
  def validate_required_opts(opts, required_keys) do
    missing_keys =
      required_keys
      |> Enum.reject(&Keyword.has_key?(opts, &1))

    if Enum.empty?(missing_keys) do
      :ok
    else
      {:error, {:missing_required_opts, missing_keys}}
    end
  end
end
