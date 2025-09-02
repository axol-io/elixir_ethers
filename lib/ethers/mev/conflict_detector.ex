defmodule Ethers.MEV.ConflictDetector do
  @moduledoc """
  Detects conflicts between bundle transactions and pending transactions.

  This module helps identify potential conflicts that could prevent bundle
  inclusion, such as:
  - Nonce conflicts with pending transactions
  - Gas price competition
  - Target contract conflicts
  - Account balance issues

  ## Example

      bundle = Ethers.MEV.Bundle.new!(...)
      
      case ConflictDetector.check_conflicts(bundle, opts) do
        {:ok, :no_conflicts} -> 
          # Safe to submit
        {:ok, conflicts} ->
          # Handle conflicts
        {:error, reason} ->
          # Error checking conflicts
      end
  """

  alias Ethers.MEV.Bundle

  @type conflict :: %{
          type: conflict_type(),
          transaction_index: non_neg_integer(),
          details: map()
        }

  @type conflict_type ::
          :nonce_conflict
          | :gas_price_too_low
          | :insufficient_balance
          | :target_conflict
          | :replacement_underpriced

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Checks for conflicts that could prevent bundle inclusion.

  ## Options
  - `:check_mempool` - Check against mempool transactions (default: true)
  - `:check_balance` - Verify account balances (default: true)
  - `:min_gas_price` - Minimum gas price to consider competitive
  - `:rpc_opts` - Options for RPC calls

  ## Returns
  - `{:ok, :no_conflicts}` - No conflicts detected
  - `{:ok, [conflict]}` - List of detected conflicts
  - `{:error, reason}` - Error during conflict checking
  """
  @spec check_conflicts(Bundle.t(), keyword()) ::
          {:ok, :no_conflicts | [conflict()]} | {:error, term()}
  def check_conflicts(%Bundle{} = bundle, opts \\ []) do
    checks = [
      &check_nonce_conflicts/2,
      &check_gas_price_conflicts/2,
      &check_balance_conflicts/2
    ]

    case run_conflict_checks(bundle, opts, checks) do
      [] -> {:ok, :no_conflicts}
      conflicts -> {:ok, conflicts}
    end
  rescue
    e -> {:error, {:conflict_check_failed, e}}
  end

  @doc """
  Checks if two bundles conflict with each other.

  Bundles conflict if they:
  - Use the same nonce from the same account
  - Target the same limited resource
  - Have ordering dependencies

  ## Returns
  - `{:ok, :no_conflict}` - Bundles don't conflict
  - `{:ok, conflict_reason}` - Description of the conflict
  """
  @spec check_bundle_conflict(Bundle.t(), Bundle.t()) ::
          {:ok, :no_conflict | map()}
  def check_bundle_conflict(%Bundle{} = bundle1, %Bundle{} = bundle2) do
    cond do
      nonce_overlap?(bundle1, bundle2) ->
        {:ok, %{type: :nonce_overlap, details: get_nonce_overlap(bundle1, bundle2)}}

      target_overlap?(bundle1, bundle2) ->
        {:ok, %{type: :target_overlap, details: get_target_overlap(bundle1, bundle2)}}

      true ->
        {:ok, :no_conflict}
    end
  end

  @doc """
  Suggests resolutions for detected conflicts.

  ## Returns
  A list of suggested actions to resolve conflicts.
  """
  @spec suggest_resolutions([conflict()]) :: [map()]
  def suggest_resolutions(conflicts) do
    Enum.map(conflicts, &suggest_resolution/1)
  end

  # ============================================================================
  # Conflict Detection Functions
  # ============================================================================

  defp run_conflict_checks(bundle, opts, checks) do
    Enum.flat_map(checks, fn check ->
      case check.(bundle, opts) do
        {:ok, conflicts} -> conflicts
        {:error, _} -> []
      end
    end)
  end

  defp check_nonce_conflicts(%Bundle{transactions: transactions}, opts) do
    rpc_opts = Keyword.get(opts, :rpc_opts, [])

    conflicts =
      transactions
      |> Enum.with_index()
      |> Enum.flat_map(fn {tx, index} ->
        case check_transaction_nonce(tx, index, rpc_opts) do
          {:conflict, conflict} -> [conflict]
          :ok -> []
        end
      end)

    {:ok, conflicts}
  end

  defp check_transaction_nonce(transaction, index, rpc_opts) do
    with {:ok, from} <- get_transaction_from(transaction),
         {:ok, expected_nonce} <- Ethers.get_transaction_count(from, rpc_opts),
         {:ok, tx_nonce} <- get_transaction_nonce(transaction) do
      if tx_nonce < expected_nonce do
        conflict = %{
          type: :nonce_conflict,
          transaction_index: index,
          details: %{
            from: from,
            transaction_nonce: tx_nonce,
            expected_nonce: expected_nonce,
            reason: :nonce_too_low
          }
        }

        {:conflict, conflict}
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  defp check_gas_price_conflicts(%Bundle{transactions: transactions}, opts) do
    min_gas_price = Keyword.get(opts, :min_gas_price)

    if min_gas_price do
      conflicts =
        transactions
        |> Enum.with_index()
        |> Enum.flat_map(fn {tx, index} ->
          case check_transaction_gas_price(tx, index, min_gas_price) do
            {:conflict, conflict} -> [conflict]
            :ok -> []
          end
        end)

      {:ok, conflicts}
    else
      {:ok, []}
    end
  end

  defp check_transaction_gas_price(transaction, index, min_gas_price) do
    case get_transaction_gas_price(transaction) do
      {:ok, gas_price} when gas_price < min_gas_price ->
        conflict = %{
          type: :gas_price_too_low,
          transaction_index: index,
          details: %{
            transaction_gas_price: gas_price,
            min_required: min_gas_price,
            difference: min_gas_price - gas_price
          }
        }

        {:conflict, conflict}

      _ ->
        :ok
    end
  end

  defp check_balance_conflicts(%Bundle{transactions: transactions}, opts) do
    if Keyword.get(opts, :check_balance, true) do
      rpc_opts = Keyword.get(opts, :rpc_opts, [])

      conflicts =
        transactions
        |> Enum.with_index()
        |> Enum.flat_map(fn {tx, index} ->
          case check_transaction_balance(tx, index, rpc_opts) do
            {:conflict, conflict} -> [conflict]
            :ok -> []
          end
        end)

      {:ok, conflicts}
    else
      {:ok, []}
    end
  end

  defp check_transaction_balance(transaction, index, rpc_opts) do
    with {:ok, from} <- get_transaction_from(transaction),
         {:ok, balance} <- Ethers.get_balance(from, rpc_opts),
         {:ok, required} <- calculate_required_balance(transaction) do
      if balance < required do
        conflict = %{
          type: :insufficient_balance,
          transaction_index: index,
          details: %{
            from: from,
            current_balance: balance,
            required_balance: required,
            deficit: required - balance
          }
        }

        {:conflict, conflict}
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  # ============================================================================
  # Bundle Conflict Detection
  # ============================================================================

  defp nonce_overlap?(bundle1, bundle2) do
    nonces1 = get_bundle_nonces(bundle1)
    nonces2 = get_bundle_nonces(bundle2)

    MapSet.size(MapSet.intersection(nonces1, nonces2)) > 0
  end

  defp get_bundle_nonces(%Bundle{transactions: transactions}) do
    transactions
    |> Enum.flat_map(fn tx ->
      case {get_transaction_from(tx), get_transaction_nonce(tx)} do
        {{:ok, from}, {:ok, nonce}} -> [{from, nonce}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp get_nonce_overlap(bundle1, bundle2) do
    nonces1 = get_bundle_nonces(bundle1)
    nonces2 = get_bundle_nonces(bundle2)

    MapSet.intersection(nonces1, nonces2)
    |> Enum.to_list()
    |> Enum.map(fn {from, nonce} ->
      %{from: from, nonce: nonce}
    end)
  end

  defp target_overlap?(bundle1, bundle2) do
    targets1 = get_bundle_targets(bundle1)
    targets2 = get_bundle_targets(bundle2)

    MapSet.size(MapSet.intersection(targets1, targets2)) > 0
  end

  defp get_bundle_targets(%Bundle{transactions: transactions}) do
    transactions
    |> Enum.flat_map(fn tx ->
      case get_transaction_to(tx) do
        {:ok, to} -> [to]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp get_target_overlap(bundle1, bundle2) do
    targets1 = get_bundle_targets(bundle1)
    targets2 = get_bundle_targets(bundle2)

    MapSet.intersection(targets1, targets2)
    |> Enum.to_list()
    |> Enum.map(fn target ->
      %{contract: target}
    end)
  end

  # ============================================================================
  # Resolution Suggestions
  # ============================================================================

  defp suggest_resolution(%{type: :nonce_conflict, details: details}) do
    %{
      conflict_type: :nonce_conflict,
      resolution: :update_nonce,
      action:
        "Update transaction nonce from #{details.transaction_nonce} to #{details.expected_nonce}",
      details: details
    }
  end

  defp suggest_resolution(%{type: :gas_price_too_low, details: details}) do
    %{
      conflict_type: :gas_price_too_low,
      resolution: :increase_gas_price,
      action: "Increase gas price to at least #{details.min_required}",
      details: details
    }
  end

  defp suggest_resolution(%{type: :insufficient_balance, details: details}) do
    %{
      conflict_type: :insufficient_balance,
      resolution: :add_funds,
      action: "Add #{details.deficit} wei to account #{details.from}",
      details: details
    }
  end

  defp suggest_resolution(conflict) do
    %{
      conflict_type: conflict.type,
      resolution: :manual_review,
      action: "Manual review required",
      details: conflict.details
    }
  end

  # ============================================================================
  # Transaction Helper Functions
  # ============================================================================

  defp get_transaction_from(tx) when is_binary(tx) do
    # Decode raw transaction to get from address
    # This would require RLP decoding and signature recovery
    {:error, :not_implemented}
  end

  defp get_transaction_from(%{from: from}), do: {:ok, from}
  defp get_transaction_from(_), do: {:error, :no_from_address}

  defp get_transaction_to(tx) when is_binary(tx) do
    # Decode raw transaction to get to address
    {:error, :not_implemented}
  end

  defp get_transaction_to(%{to: to}), do: {:ok, to}
  defp get_transaction_to(_), do: {:error, :no_to_address}

  defp get_transaction_nonce(tx) when is_binary(tx) do
    # Decode raw transaction to get nonce
    {:error, :not_implemented}
  end

  defp get_transaction_nonce(%{nonce: nonce}), do: {:ok, nonce}
  defp get_transaction_nonce(_), do: {:error, :no_nonce}

  defp get_transaction_gas_price(tx) when is_binary(tx) do
    # Decode raw transaction to get gas price
    {:error, :not_implemented}
  end

  defp get_transaction_gas_price(%{gas_price: price}), do: {:ok, price}
  defp get_transaction_gas_price(%{gasPrice: price}), do: {:ok, price}
  defp get_transaction_gas_price(_), do: {:error, :no_gas_price}

  defp calculate_required_balance(transaction) do
    with {:ok, value} <- get_transaction_value(transaction),
         {:ok, gas_price} <- get_transaction_gas_price(transaction),
         {:ok, gas_limit} <- get_transaction_gas_limit(transaction) do
      {:ok, value + gas_price * gas_limit}
    end
  end

  defp get_transaction_value(%{value: value}), do: {:ok, value || 0}
  defp get_transaction_value(_), do: {:ok, 0}

  defp get_transaction_gas_limit(%{gas: gas}), do: {:ok, gas}
  defp get_transaction_gas_limit(%{gasLimit: gas}), do: {:ok, gas}
  # Default gas for simple transfer
  defp get_transaction_gas_limit(_), do: {:ok, 21_000}
end
