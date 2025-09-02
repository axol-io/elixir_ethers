defmodule Ethers.MEV.TestHelpers do
  @moduledoc """
  Test helpers for MEV integration tests.

  Provides utilities for testing MEV functionality with Anvil,
  including bundle creation, transaction signing, and Flashbots
  relay simulation.
  """

  alias Ethers.MEV.Bundle
  alias Ethers.Signer.Local
  alias Ethers.Transaction
  alias Ethers.Utils

  # Default test accounts from Anvil
  @default_accounts [
    %{
      address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      private_key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    },
    %{
      address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      private_key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    },
    %{
      address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      private_key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
    }
  ]

  @doc """
  Starts an Anvil instance for testing.

  ## Options
  - `:port` - Port to run Anvil on (default: 8545)
  - `:fork_url` - Optional URL to fork from
  - `:chain_id` - Chain ID (default: 1)
  - `:block_time` - Auto-mine block time in seconds

  ## Returns
  - `{:ok, pid}` - Anvil process PID
  - `{:error, reason}` - Error starting Anvil
  """
  def start_anvil(opts \\ []) do
    port = Keyword.get(opts, :port, 8545)
    chain_id = Keyword.get(opts, :chain_id, 1)

    args = [
      "--port",
      to_string(port),
      "--chain-id",
      to_string(chain_id),
      "--accounts",
      "10",
      "--balance",
      "10000",
      "--mnemonic",
      "test test test test test test test test test test test junk"
    ]

    args =
      case Keyword.get(opts, :fork_url) do
        nil -> args
        url -> args ++ ["--fork-url", url]
      end

    args =
      case Keyword.get(opts, :block_time) do
        nil -> args
        time -> args ++ ["--block-time", to_string(time)]
      end

    case System.cmd("anvil", args, into: IO.stream(:stdio, :line)) do
      {_, 0} -> {:ok, :started}
      {_, code} -> {:error, {:anvil_failed, code}}
    end
  end

  @doc """
  Creates a test bundle with simple transfer transactions.

  ## Options
  - `:transaction_count` - Number of transactions (default: 2)
  - `:block_number` - Target block (default: current + 1)
  - `:from_account` - Account index to send from (default: 0)
  - `:to_account` - Account index to send to (default: 1)
  - `:value` - Wei to transfer per transaction (default: 1000000000000000000)
  """
  def create_test_bundle(opts \\ []) do
    tx_count = Keyword.get(opts, :transaction_count, 2)
    from_account = get_test_account(Keyword.get(opts, :from_account, 0))
    to_account = get_test_account(Keyword.get(opts, :to_account, 1))
    value = Keyword.get(opts, :value, 1_000_000_000_000_000_000)

    transactions =
      Enum.map(1..tx_count, fn i ->
        create_test_transaction(
          from: from_account.address,
          to: to_account.address,
          value: value,
          nonce: i - 1,
          private_key: from_account.private_key
        )
      end)

    block_number =
      case Keyword.get(opts, :block_number) do
        nil -> get_next_block_number()
        num -> num
      end

    Bundle.new!(%{
      transactions: transactions,
      block_number: block_number
    })
  end

  @doc """
  Creates and signs a test transaction.

  ## Options
  - `:from` - Sender address
  - `:to` - Recipient address
  - `:value` - Wei to send
  - `:nonce` - Transaction nonce
  - `:gas_price` - Gas price in wei
  - `:gas_limit` - Gas limit
  - `:data` - Transaction data
  - `:private_key` - Private key for signing
  """
  def create_test_transaction(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    value = Keyword.get(opts, :value, 0)
    nonce = Keyword.get(opts, :nonce, 0)
    # 20 gwei
    gas_price = Keyword.get(opts, :gas_price, 20_000_000_000)
    gas_limit = Keyword.get(opts, :gas_limit, 21_000)
    data = Keyword.get(opts, :data, "")
    private_key = Keyword.fetch!(opts, :private_key)

    tx = %Transaction.Legacy{
      nonce: nonce,
      gas_price: gas_price,
      gas: gas_limit,
      to: to,
      value: value,
      input: data,
      chain_id: 1
    }

    {:ok, signed} = Local.sign_transaction(tx, private_key: private_key, from: from)
    signed
  end

  @doc """
  Gets a test account by index.
  """
  def get_test_account(index) when index >= 0 and index < length(@default_accounts) do
    Enum.at(@default_accounts, index)
  end

  @doc """
  Gets all test accounts.
  """
  def get_test_accounts, do: @default_accounts

  @doc """
  Creates a mock Flashbots relay server for testing.

  Returns a function that can be used with Req.Test to mock responses.

  ## Example

      Req.Test.expect(FlashbotsRelay, create_mock_relay(%{
        "eth_sendBundle" => {:ok, "0xbundle_hash"},
        "eth_callBundle" => {:ok, %{results: [], totalGasUsed: 0}}
      }))
  """
  def create_mock_relay(responses \\ %{}) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      {:ok, request} = Jason.decode(body)

      method = request["method"]

      response =
        case Map.get(responses, method) do
          {:ok, result} ->
            %{
              jsonrpc: "2.0",
              id: request["id"],
              result: result
            }

          {:error, error} ->
            %{
              jsonrpc: "2.0",
              id: request["id"],
              error: %{
                code: -32_000,
                message: error
              }
            }

          nil ->
            %{
              jsonrpc: "2.0",
              id: request["id"],
              error: %{
                code: -32_601,
                message: "Method not found"
              }
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  @doc """
  Waits for a specific block number to be mined.

  ## Options
  - `:timeout` - Maximum time to wait in ms (default: 30000)
  - `:check_interval` - How often to check in ms (default: 1000)
  """
  def wait_for_block(target_block, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    check_interval = Keyword.get(opts, :check_interval, 1_000)
    rpc_opts = Keyword.get(opts, :rpc_opts, [])

    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_block_loop(target_block, deadline, check_interval, rpc_opts)
  end

  defp wait_for_block_loop(target_block, deadline, check_interval, rpc_opts) do
    case Ethers.current_block_number(rpc_opts) do
      {:ok, current} when current >= target_block ->
        {:ok, current}

      {:ok, _current} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(check_interval)
          wait_for_block_loop(target_block, deadline, check_interval, rpc_opts)
        end

      error ->
        error
    end
  end

  @doc """
  Mines blocks in Anvil.

  ## Parameters
  - `count` - Number of blocks to mine
  - `opts` - RPC options
  """
  def mine_blocks(count, opts \\ []) do
    rpc_opts = Keyword.get(opts, :rpc_opts, url: "http://localhost:8545")

    # Use Anvil's evm_mine RPC method
    params = if count > 1, do: [Utils.integer_to_hex(count)], else: []

    case Ethereumex.HttpClient.request("evm_mine", params, rpc_opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Sets up a test environment with funded accounts.

  Creates accounts with ETH balance for testing.

  ## Options
  - `:account_count` - Number of accounts to create (default: 3)
  - `:balance` - ETH balance per account in wei (default: 10 ETH)
  """
  def setup_test_accounts(opts \\ []) do
    account_count = Keyword.get(opts, :account_count, 3)
    # 10 ETH - unused as Anvil pre-funds accounts
    _balance = Keyword.get(opts, :balance, 10_000_000_000_000_000_000)

    accounts = Enum.take(@default_accounts, account_count)

    # In Anvil, accounts are pre-funded, but this could fund them if needed
    {:ok, accounts}
  end

  @doc """
  Verifies a bundle was included in a block.

  Checks if all bundle transactions appear in the specified block.

  ## Parameters
  - `bundle` - The bundle to check
  - `block_number` - The block to check
  - `opts` - RPC options
  """
  def verify_bundle_inclusion(%Bundle{} = bundle, block_number, opts \\ []) do
    rpc_opts = Keyword.get(opts, :rpc_opts, [])

    # Get block with transactions using Ethereumex directly
    block_hex = Utils.integer_to_hex(block_number)

    case Ethereumex.HttpClient.eth_get_block_by_number(block_hex, true, rpc_opts) do
      {:ok, block} ->
        block_txs = Map.get(block, "transactions", [])
        bundle_hashes = get_bundle_transaction_hashes(bundle)

        included =
          Enum.all?(bundle_hashes, fn hash ->
            Enum.any?(block_txs, fn tx ->
              Map.get(tx, "hash") == hash
            end)
          end)

        {:ok, included}

      error ->
        error
    end
  end

  defp get_bundle_transaction_hashes(%Bundle{transactions: transactions}) do
    Enum.map(transactions, fn tx ->
      # Calculate transaction hash
      # This would need proper implementation
      Utils.hex_encode(:crypto.hash(:sha256, tx))
    end)
  end

  defp get_next_block_number do
    case Ethers.current_block_number() do
      {:ok, current} -> current + 1
      _ -> 1
    end
  end

  @doc """
  Creates test options for MEV operations.

  Returns properly configured options for testing with Flashbots.

  ## Options
  - `:network` - Network to use (default: :sepolia)
  - `:account_index` - Test account index for signing (default: 0)
  """
  def create_test_opts(opts \\ []) do
    network = Keyword.get(opts, :network, :sepolia)
    account = get_test_account(Keyword.get(opts, :account_index, 0))

    [
      provider: Ethers.MEV.Providers.Flashbots,
      signer: Ethers.Signer.Local,
      signer_opts: [private_key: account.private_key],
      network: network,
      rpc_opts: [url: "http://localhost:8545"]
    ]
  end
end
