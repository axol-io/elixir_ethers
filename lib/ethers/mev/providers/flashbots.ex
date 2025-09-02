defmodule Ethers.MEV.Providers.Flashbots do
  @moduledoc """
  Flashbots MEV provider implementation.

  This module implements the MEV.Provider behaviour for interacting with
  Flashbots relay infrastructure. It provides bundle submission, simulation,
  and monitoring capabilities through the Flashbots JSON-RPC API.

  ## Configuration

  The provider requires the following options:
  - `:signer` - Module implementing transaction signing (required)
  - `:signer_opts` - Options for the signer (required, must include `:private_key`)
  - `:network` - Network to use (:mainnet or :sepolia, defaults to :mainnet)
  - `:relay_url` - Custom relay URL (optional, overrides network default)

  ## Example

      alias Ethers.MEV.Bundle
      alias Ethers.MEV.Providers.Flashbots

      bundle = Bundle.new!(%{
        transactions: [signed_tx1, signed_tx2],
        block_number: 12345678
      })

      opts = [
        signer: Ethers.Signer.Local,
        signer_opts: [private_key: private_key],
        network: :mainnet
      ]

      {:ok, bundle_hash} = Flashbots.send_bundle(bundle, opts)
  """

  @behaviour Ethers.MEV.Provider

  alias Ethers.MEV.Bundle
  alias Ethers.Types
  alias Ethers.Utils

  import Ethers, only: [keccak_module: 0]

  require Logger

  # Relay URLs by network
  @mainnet_relay "https://relay.flashbots.net"
  @sepolia_relay "https://relay-sepolia.flashbots.net"

  # JSON-RPC version
  @json_rpc_version "2.0"

  # ============================================================================
  # Public API - Provider Callbacks
  # ============================================================================

  @impl true
  @doc """
  Sends a bundle to the Flashbots relay.

  Uses the `eth_sendBundle` JSON-RPC method.
  """
  @spec send_bundle(Bundle.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_bundle(%Bundle{} = bundle, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         {:ok, encoded_bundle} <- Bundle.encode(bundle),
         {:ok, request_body} <- build_request("eth_sendBundle", [encoded_bundle]),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_send_bundle_response(response)
    end
  end

  @impl true
  @doc """
  Simulates a bundle execution.

  Uses the `eth_callBundle` JSON-RPC method.
  """
  @spec simulate_bundle(Bundle.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def simulate_bundle(%Bundle{} = bundle, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         {:ok, encoded_bundle} <- Bundle.encode(bundle),
         state_block <- Keyword.get(opts, :state_block, "latest"),
         params <- [encoded_bundle, state_block],
         {:ok, request_body} <- build_request("eth_callBundle", params),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_simulate_response(response)
    end
  end

  @impl true
  @doc """
  Gets the status of a submitted bundle.

  Uses the `flashbots_getBundleStats` JSON-RPC method.
  """
  @spec get_bundle_status(String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_bundle_status(bundle_hash, block_number, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         params <- [
           %{
             bundleHash: bundle_hash,
             blockNumber: Utils.integer_to_hex(block_number)
           }
         ],
         {:ok, request_body} <- build_request("flashbots_getBundleStats", params),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_bundle_stats_response(response)
    end
  end

  @impl true
  @doc """
  Cancels a pending bundle.

  Uses the `flashbots_cancelBundle` JSON-RPC method.
  """
  @spec cancel_bundle(String.t(), keyword()) :: {:ok, :cancelled} | {:error, term()}
  def cancel_bundle(bundle_hash, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         {:ok, request_body} <- build_request("flashbots_cancelBundle", [bundle_hash]),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_cancel_response(response)
    end
  end

  @impl true
  @doc """
  Gets user statistics from Flashbots.

  Uses the `flashbots_getUserStats` JSON-RPC method.
  """
  @spec get_user_stats(Types.t_address(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_user_stats(address, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         block_number <- Keyword.get(opts, :block_number, "latest"),
         params <- [
           %{
             address: address,
             blockNumber: encode_block_number(block_number)
           }
         ],
         {:ok, request_body} <- build_request("flashbots_getUserStats", params),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_user_stats_response(response)
    end
  end

  @doc """
  Sends a private transaction through Flashbots.

  Uses the `eth_sendPrivateTransaction` JSON-RPC method.
  """
  @spec send_private_transaction(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_private_transaction(transaction, opts) do
    with :ok <- validate_opts(opts, [:signer, :signer_opts]),
         max_block <- Keyword.get(opts, :max_block_number),
         preferences <- build_preferences(opts),
         params <- build_private_tx_params(transaction, max_block, preferences),
         {:ok, request_body} <- build_request("eth_sendPrivateTransaction", params),
         {:ok, response} <- send_signed_request(request_body, opts) do
      handle_private_tx_response(response)
    end
  end

  # ============================================================================
  # Private - Request Building
  # ============================================================================

  defp build_request(method, params) do
    request = %{
      jsonrpc: @json_rpc_version,
      id: generate_request_id(),
      method: method,
      params: params
    }

    {:ok, Jason.encode!(request)}
  rescue
    e -> {:error, {:encoding_error, e}}
  end

  defp generate_request_id do
    :erlang.unique_integer([:positive, :monotonic])
  end

  # ============================================================================
  # Private - HTTP Communication
  # ============================================================================

  defp send_signed_request(request_body, opts) do
    with {:ok, {signer_address, signature}} <- sign_request(request_body, opts),
         relay_url <- get_relay_url(opts),
         headers <- build_headers(signer_address, signature),
         {:ok, response} <- http_post(relay_url, request_body, headers) do
      parse_response(response)
    end
  end

  defp sign_request(request_body, opts) do
    signer = Keyword.fetch!(opts, :signer)
    signer_opts = Keyword.fetch!(opts, :signer_opts)

    # Hash the request body for signing
    message_hash = keccak_module().hash_256(request_body)

    case signer.sign_flashbots_request(message_hash, signer_opts) do
      {:ok, result} -> {:ok, result}
      error -> {:error, {:signing_failed, error}}
    end
  end

  defp build_headers(signer_address, signature) do
    [
      {"Content-Type", "application/json"},
      {"X-Flashbots-Signature", "#{signer_address}:#{signature}"}
    ]
  end

  defp http_post(url, body, headers) do
    # Use Req for HTTP requests to Flashbots relay
    req_opts = [
      method: :post,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      receive_timeout: 30_000
    ]

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status_code, body: response_body}} ->
        {:error, {:http_error, status_code, response_body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp parse_response(response_body) when is_map(response_body) do
    # Req automatically parses JSON responses
    {:ok, response_body}
  end

  defp parse_response(response_body) when is_binary(response_body) do
    # Fallback for raw string responses
    case Jason.decode(response_body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, {:invalid_json, response_body}}
    end
  end

  defp parse_response(response_body) do
    {:error, {:unexpected_response_format, response_body}}
  end

  # ============================================================================
  # Private - Response Handlers
  # ============================================================================

  defp handle_send_bundle_response(%{"result" => bundle_hash}) when is_binary(bundle_hash) do
    {:ok, bundle_hash}
  end

  defp handle_send_bundle_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_send_bundle_response(_) do
    {:error, :invalid_response}
  end

  defp handle_simulate_response(%{"result" => result}) when is_map(result) do
    {:ok, parse_simulation_result(result)}
  end

  defp handle_simulate_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_simulate_response(_) do
    {:error, :invalid_response}
  end

  defp handle_bundle_stats_response(%{"result" => stats}) when is_map(stats) do
    {:ok, parse_bundle_stats(stats)}
  end

  defp handle_bundle_stats_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_bundle_stats_response(_) do
    {:error, :invalid_response}
  end

  defp handle_cancel_response(%{"result" => "ok"}) do
    {:ok, :cancelled}
  end

  defp handle_cancel_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_cancel_response(_) do
    {:error, :invalid_response}
  end

  defp handle_user_stats_response(%{"result" => stats}) when is_map(stats) do
    {:ok, parse_user_stats(stats)}
  end

  defp handle_user_stats_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_user_stats_response(_) do
    {:error, :invalid_response}
  end

  defp handle_private_tx_response(%{"result" => tx_hash}) when is_binary(tx_hash) do
    {:ok, tx_hash}
  end

  defp handle_private_tx_response(%{"error" => error}) do
    parse_rpc_error(error)
  end

  defp handle_private_tx_response(_) do
    {:error, :invalid_response}
  end

  # ============================================================================
  # Private - Error Parsing
  # ============================================================================

  defp parse_rpc_error(%{"message" => message, "code" => code}) do
    error_atom = map_error_message(message)
    {:error, {error_atom, code, message}}
  end

  defp parse_rpc_error(%{"message" => message}) do
    error_atom = map_error_message(message)
    {:error, {error_atom, message}}
  end

  defp parse_rpc_error(error) do
    {:error, {:rpc_error, error}}
  end

  defp map_error_message(message) when is_binary(message) do
    cond do
      String.contains?(message, "bundle not found") -> :bundle_not_found
      String.contains?(message, "invalid signature") -> :invalid_signature
      String.contains?(message, "block already passed") -> :block_passed
      String.contains?(message, "rate limit") -> :rate_limited
      String.contains?(message, "invalid bundle") -> :invalid_bundle
      true -> :unknown_error
    end
  end

  defp map_error_message(_), do: :unknown_error

  # ============================================================================
  # Private - Result Parsing
  # ============================================================================

  defp parse_simulation_result(result) do
    %{
      results: Map.get(result, "results", []),
      total_gas_used: Map.get(result, "totalGasUsed", 0),
      coinbase_diff: Map.get(result, "coinbaseDiff"),
      gas_fees: Map.get(result, "gasFees"),
      state_block: Map.get(result, "stateBlockNumber")
    }
  end

  defp parse_bundle_stats(stats) do
    %{
      is_simulated: Map.get(stats, "isSimulated", false),
      is_sent_to_miners: Map.get(stats, "isSentToMiners", false),
      is_high_priority: Map.get(stats, "isHighPriority", false),
      simulated_at: Map.get(stats, "simulatedAt"),
      submitted_at: Map.get(stats, "submittedAt"),
      miner_response_at: Map.get(stats, "minerResponseAt")
    }
  end

  defp parse_user_stats(stats) do
    %{
      is_high_priority: Map.get(stats, "isHighPriority", false),
      all_time_miner_payments: Map.get(stats, "allTimeMinerPayments", "0"),
      all_time_gas_simulated: Map.get(stats, "allTimeGasSimulated", "0"),
      last_7d_miner_payments: Map.get(stats, "last7dMinerPayments", "0"),
      last_7d_gas_simulated: Map.get(stats, "last7dGasSimulated", "0")
    }
  end

  # ============================================================================
  # Private - Utility Functions
  # ============================================================================

  defp validate_opts(opts, required_keys) do
    Ethers.MEV.Provider.validate_required_opts(opts, required_keys)
  end

  defp get_relay_url(opts) do
    case Keyword.get(opts, :relay_url) do
      nil ->
        case Keyword.get(opts, :network, :mainnet) do
          :mainnet -> @mainnet_relay
          :sepolia -> @sepolia_relay
          network -> raise ArgumentError, "Unknown network: #{inspect(network)}"
        end

      url ->
        url
    end
  end

  defp encode_block_number(number) when is_integer(number) do
    Utils.integer_to_hex(number)
  end

  defp encode_block_number("latest"), do: "latest"
  defp encode_block_number(hex) when is_binary(hex), do: hex

  defp build_private_tx_params(transaction, max_block, preferences) do
    params = [transaction]

    params =
      if max_block do
        params ++ [Utils.integer_to_hex(max_block)]
      else
        params
      end

    if preferences do
      params ++ [preferences]
    else
      params
    end
  end

  defp build_preferences(opts) do
    fast = Keyword.get(opts, :fast)
    privacy = Keyword.get(opts, :privacy)

    if fast || privacy do
      %{}
      |> maybe_add_preference(:fast, fast)
      |> maybe_add_preference(:privacy, privacy)
    else
      nil
    end
  end

  defp maybe_add_preference(map, _key, nil), do: map
  defp maybe_add_preference(map, key, value), do: Map.put(map, key, value)
end
