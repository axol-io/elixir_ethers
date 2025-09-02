defmodule Ethers.MEV.Bundle do
  alias Ethers.MEV.Utils

  @moduledoc """
  Represents a bundle of transactions for MEV submission.

  A bundle is an ordered list of transactions that are executed atomically
  and sequentially. Bundles can target specific blocks and include timing
  constraints for inclusion.

  ## Business Logic

  This module handles the core domain logic for MEV bundles:
  - Bundle validation (non-empty transactions, valid block numbers)
  - Transaction integrity checking
  - Timestamp range validation

  ## Functional Composition

  All modification functions return updated bundles, supporting pipeline composition:

      bundle
      |> add_transaction(tx)
      |> set_timing_constraints(min, max)
      |> allow_reverts(hashes)
  """

  alias Ethers.Types
  alias Ethers.Utils

  @enforce_keys [:transactions, :block_number]
  defstruct [
    :transactions,
    :block_number,
    :min_timestamp,
    :max_timestamp,
    :reverting_tx_hashes,
    :replacement_uuid,
    # Add max_block field for future use
    :max_block
  ]

  @type transaction_input :: map() | String.t() | binary()

  @type t :: %__MODULE__{
          transactions: [transaction_input()],
          block_number: non_neg_integer(),
          min_timestamp: non_neg_integer() | nil,
          max_timestamp: non_neg_integer() | nil,
          reverting_tx_hashes: [Types.t_hash()] | nil,
          replacement_uuid: String.t() | nil,
          max_block: non_neg_integer() | nil
        }

  # ============================================================================
  # Public API - Creation
  # ============================================================================

  @doc """
  Creates a new bundle with validation.

  ## Parameters
  - `params` - Map containing bundle parameters:
    - `:transactions` - List of signed transactions (required)
    - `:block_number` - Target block number (required)
    - `:min_timestamp` - Minimum Unix timestamp for inclusion (optional)
    - `:max_timestamp` - Maximum Unix timestamp for inclusion (optional)
    - `:reverting_tx_hashes` - Transaction hashes allowed to revert (optional)
    - `:replacement_uuid` - UUID for bundle replacement (optional)

  ## Examples
      
      iex> Ethers.MEV.Bundle.new(%{
      ...>   transactions: [signed_tx1, signed_tx2],
      ...>   block_number: 12345
      ...> })
      {:ok, %Ethers.MEV.Bundle{...}}
      
      iex> Ethers.MEV.Bundle.new(%{transactions: [], block_number: 12345})
      {:error, :empty_bundle}
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(params) when is_map(params) do
    with {:ok, normalized} <- normalize_params(params),
         :ok <- validate_bundle(normalized) do
      {:ok, struct!(__MODULE__, normalized)}
    end
  end

  @doc """
  Creates a new bundle, raising on error.

  ## Examples
      
      iex> Ethers.MEV.Bundle.new!(%{
      ...>   transactions: [signed_tx],
      ...>   block_number: 12345
      ...> })
      %Ethers.MEV.Bundle{...}
  """
  @spec new!(map()) :: t()
  def new!(params) when is_map(params) do
    case new(params) do
      {:ok, bundle} -> bundle
      {:error, reason} -> raise ArgumentError, "Failed to create bundle: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # Public API - Transformations (Functional)
  # ============================================================================

  @doc """
  Adds a transaction to the bundle.

  ## Parameters
  - `bundle` - The bundle to modify
  - `transaction` - The transaction to add

  ## Examples
      
      iex> bundle |> Ethers.MEV.Bundle.add_transaction(new_tx)
      %Ethers.MEV.Bundle{transactions: [..., new_tx]}
  """
  @spec add_transaction(t(), transaction_input()) :: t()
  def add_transaction(%__MODULE__{transactions: txs} = bundle, transaction) do
    %{bundle | transactions: txs ++ [transaction]}
  end

  @doc """
  Sets the target block(s) for the bundle.

  ## Parameters
  - `bundle` - The bundle to modify
  - `block_number` - The target block number
  - `max_block` - Optional maximum block number for inclusion

  ## Examples
      
      iex> bundle |> Ethers.MEV.Bundle.set_block_target(12345)
      %Ethers.MEV.Bundle{block_number: 12345}
  """
  @spec set_block_target(t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def set_block_target(bundle, block_number, max_block \\ nil) do
    updates =
      %{block_number: block_number}
      |> maybe_put(:max_block, max_block)

    struct!(bundle, updates)
  end

  @doc """
  Sets timing constraints for the bundle.

  ## Parameters
  - `bundle` - The bundle to modify
  - `min_timestamp` - Minimum Unix timestamp for inclusion
  - `max_timestamp` - Maximum Unix timestamp for inclusion

  ## Examples
      
      iex> bundle |> Ethers.MEV.Bundle.set_timing_constraints(1234567890, 1234567900)
      %Ethers.MEV.Bundle{min_timestamp: 1234567890, max_timestamp: 1234567900}
  """
  @spec set_timing_constraints(t(), non_neg_integer() | nil, non_neg_integer() | nil) :: t()
  def set_timing_constraints(bundle, min_timestamp, max_timestamp) do
    %{bundle | min_timestamp: min_timestamp, max_timestamp: max_timestamp}
  end

  @doc """
  Sets transaction hashes that are allowed to revert.

  ## Parameters
  - `bundle` - The bundle to modify
  - `tx_hashes` - List of transaction hashes that can revert

  ## Examples
      
      iex> bundle |> Ethers.MEV.Bundle.allow_reverts(["0xabc...", "0xdef..."])
      %Ethers.MEV.Bundle{reverting_tx_hashes: ["0xabc...", "0xdef..."]}
  """
  @spec allow_reverts(t(), [Types.t_hash()] | nil) :: t()
  def allow_reverts(bundle, tx_hashes) do
    %{bundle | reverting_tx_hashes: normalize_hashes(tx_hashes)}
  end

  @doc """
  Sets a replacement UUID for the bundle.

  This allows replacing a previously submitted bundle with the same UUID.

  ## Parameters
  - `bundle` - The bundle to modify  
  - `uuid` - Replacement UUID

  ## Examples
      
      iex> bundle |> Ethers.MEV.Bundle.set_replacement_uuid("123e4567-e89b-12d3-a456-426614174000")
      %Ethers.MEV.Bundle{replacement_uuid: "123e4567-e89b-12d3-a456-426614174000"}
  """
  @spec set_replacement_uuid(t(), String.t() | nil) :: t()
  def set_replacement_uuid(bundle, uuid) do
    %{bundle | replacement_uuid: uuid}
  end

  # ============================================================================
  # Public API - Encoding
  # ============================================================================

  @doc """
  Encodes the bundle for transmission to an MEV provider.

  ## Parameters
  - `bundle` - The bundle to encode

  ## Returns
  A map suitable for JSON encoding and transmission.
  """
  @spec encode(t()) :: {:ok, map()} | {:error, term()}
  def encode(%__MODULE__{} = bundle) do
    encoded =
      %{
        txs: encode_transactions(bundle.transactions),
        blockNumber: Utils.integer_to_hex(bundle.block_number)
      }
      |> maybe_put(:minTimestamp, bundle.min_timestamp)
      |> maybe_put(:maxTimestamp, bundle.max_timestamp)
      |> maybe_put(:revertingTxHashes, bundle.reverting_tx_hashes)
      |> maybe_put(:replacementUuid, bundle.replacement_uuid)

    {:ok, encoded}
  rescue
    e -> {:error, e}
  end

  # ============================================================================
  # Private - Parameter Normalization
  # ============================================================================

  defp normalize_params(params) do
    normalized = %{
      transactions: get_param(params, :transactions),
      block_number: get_param(params, :block_number),
      min_timestamp: get_param(params, :min_timestamp),
      max_timestamp: get_param(params, :max_timestamp),
      reverting_tx_hashes: normalize_hashes(get_param(params, :reverting_tx_hashes)),
      replacement_uuid: get_param(params, :replacement_uuid)
    }

    {:ok, normalized}
  end

  defp get_param(params, key) do
    params[key] || params[Atom.to_string(key)]
  end

  # ============================================================================
  # Private - Validation (Business Logic)
  # ============================================================================

  defp validate_bundle(params) do
    validators = [
      &validate_required_fields/1,
      &validate_transactions/1,
      &validate_block_number/1,
      &validate_timestamp_range/1
    ]

    run_validators(params, validators)
  end

  defp run_validators(params, validators) do
    Enum.reduce_while(validators, :ok, fn validator, _acc ->
      case validator.(params) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_required_fields(%{transactions: nil}), do: {:error, :empty_bundle}
  defp validate_required_fields(%{block_number: nil}), do: {:error, :invalid_block_number}
  defp validate_required_fields(_), do: :ok

  defp validate_transactions(%{transactions: []}), do: {:error, :empty_bundle}

  defp validate_transactions(%{transactions: txs}) when is_list(txs) do
    if Enum.all?(txs, &valid_transaction?/1) do
      :ok
    else
      {:error, :invalid_transactions}
    end
  end

  defp validate_transactions(_), do: {:error, :invalid_transactions}

  defp valid_transaction?(%{__struct__: _}), do: true

  defp valid_transaction?(tx) when is_binary(tx) do
    case Utils.hex_decode(tx) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_transaction?(_), do: false

  defp validate_block_number(%{block_number: n}) when is_integer(n) and n > 0, do: :ok
  defp validate_block_number(_), do: {:error, :invalid_block_number}

  defp validate_timestamp_range(%{min_timestamp: min, max_timestamp: max})
       when is_integer(min) and is_integer(max) and min > max do
    {:error, :invalid_timestamp_range}
  end

  defp validate_timestamp_range(_), do: :ok

  # ============================================================================
  # Private - Encoding Helpers
  # ============================================================================

  defp encode_transactions(transactions) do
    Enum.map(transactions, &encode_transaction/1)
  end

  defp encode_transaction(%{__struct__: _} = tx) do
    tx
    |> Ethers.Transaction.encode()
    |> Utils.hex_encode()
  end

  defp encode_transaction(raw_tx) when is_binary(raw_tx) do
    ensure_hex_prefix(raw_tx)
  end

  # ============================================================================
  # Private - Utility Functions
  # ============================================================================

  defp normalize_hashes(nil), do: nil

  defp normalize_hashes(hashes) when is_list(hashes) do
    Enum.map(hashes, &ensure_hex_prefix/1)
  end

  defp ensure_hex_prefix(<<"0x", _::binary>> = hash), do: hash
  defp ensure_hex_prefix(hash) when is_binary(hash), do: "0x" <> hash

  defp maybe_put(map, key, value), do: Ethers.MEV.Utils.maybe_put(map, key, value)
end
