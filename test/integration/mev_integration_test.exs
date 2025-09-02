defmodule Ethers.MEV.IntegrationTest do
  @moduledoc """
  Integration tests for MEV functionality with Anvil.

  These tests require Anvil to be running:
  ```
  anvil --port 8545
  ```
  """

  use ExUnit.Case, async: false

  alias Ethers.MEV
  alias Ethers.MEV.Bundle
  alias Ethers.MEV.TestHelpers
  alias Ethers.Transaction
  alias Ethers.Utils

  @anvil_url "http://localhost:8545"
  @test_timeout 30_000

  setup_all do
    # Start Anvil if not already running
    case Ethereumex.HttpClient.eth_block_number(url: @anvil_url) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        IO.puts("Starting Anvil for integration tests...")
        TestHelpers.start_anvil(port: 8545)
        Process.sleep(2000)
    end

    :ok
  end

  setup do
    # Get test accounts
    accounts = TestHelpers.get_test_accounts()

    # Configure RPC
    rpc_opts = [url: @anvil_url]

    {:ok, accounts: accounts, rpc_opts: rpc_opts}
  end

  describe "Bundle Creation and Validation" do
    test "creates a valid bundle from transactions", %{accounts: accounts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      # Create test transactions
      tx1 =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 1_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      tx2 =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 2_000_000_000_000_000,
          nonce: 1,
          private_key: from.private_key
        )

      # Create bundle
      {:ok, bundle} = MEV.create_bundle([tx1, tx2], 100)

      assert %Bundle{} = bundle
      assert length(bundle.transactions) == 2
      assert bundle.block_number == 100
    end

    test "validates bundle constraints", %{accounts: accounts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      tx =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 1_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      {:ok, bundle} = MEV.create_bundle([tx], 100)

      # Add timing constraints
      bundle =
        bundle
        |> Bundle.set_timing_constraints(1000, 2000)
        |> Bundle.allow_reverts(["0xabc"])

      assert bundle.min_timestamp == 1000
      assert bundle.max_timestamp == 2000
      assert bundle.reverting_tx_hashes == ["0xabc"]
    end
  end

  describe "Pipeline Interface" do
    test "pipeline bundle creation and simulation", %{accounts: accounts, rpc_opts: rpc_opts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      # Get current block
      {:ok, current_block} = Ethers.current_block_number(rpc_opts)

      # Create transactions
      txs =
        for i <- 0..2 do
          TestHelpers.create_test_transaction(
            from: from.address,
            to: to.address,
            value: 1_000_000_000_000_000,
            nonce: i,
            private_key: from.private_key
          )
        end

      # Pipeline operations
      bundle =
        txs
        |> MEV.pipe_bundle(block_number: current_block + 1)
        |> MEV.with_timing(min: 1000, max: 2000)

      assert %Bundle{} = bundle
      assert length(bundle.transactions) == 3
      assert bundle.min_timestamp == 1000
      assert bundle.max_timestamp == 2000
    end
  end

  describe "Bundle Monitoring" do
    @tag :skip
    test "monitors bundle inclusion", %{accounts: accounts, rpc_opts: rpc_opts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      tx =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 1_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      {:ok, current_block} = Ethers.current_block_number(rpc_opts)
      {:ok, bundle} = MEV.create_bundle([tx], current_block + 1)

      # This would require actual Flashbots integration
      # For now, we test the monitoring structure
      {:ok, monitor} =
        MEV.monitor_bundle(
          "0xbundle_hash",
          current_block + 1,
          provider: MockProvider,
          provider_opts: [],
          check_interval: 100,
          max_wait: 5
        )

      assert is_pid(monitor)

      # Clean up
      GenServer.stop(monitor)
    end
  end

  describe "Conflict Detection" do
    test "detects nonce conflicts", %{accounts: accounts, rpc_opts: rpc_opts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      # Create conflicting transactions (same nonce)
      tx1 =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 1_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      tx2 =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 2_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      {:ok, bundle} = MEV.create_bundle([tx1, tx2], 100)

      # Check for conflicts
      {:ok, conflicts} = MEV.ConflictDetector.check_conflicts(bundle, rpc_opts: rpc_opts)

      # Should detect internal nonce conflict
      assert conflicts != :no_conflicts
    end
  end

  describe "Retry Pipeline" do
    test "retries failed submissions with backoff", %{accounts: accounts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      tx =
        TestHelpers.create_test_transaction(
          from: from.address,
          to: to.address,
          value: 1_000_000_000_000_000,
          nonce: 0,
          private_key: from.private_key
        )

      {:ok, bundle} = MEV.create_bundle([tx], 100)

      # Test retry strategy
      strategy =
        MEV.RetryStrategy.exponential(
          base_delay: 100,
          max_delay: 1000,
          jitter: false
        )

      # Calculate delays for multiple attempts
      delays =
        for i <- 1..5 do
          MEV.RetryStrategy.calculate_delay(strategy, attempt: i)
        end

      assert delays == [100, 200, 400, 800, 1000]
    end
  end

  describe "Circuit Breaker" do
    test "circuit breaker opens after failures" do
      {:ok, breaker} =
        MEV.CircuitBreaker.start_link(
          providers: [:test_provider],
          threshold: 3,
          timeout: 1000
        )

      # Simulate failures
      for _ <- 1..3 do
        MEV.CircuitBreaker.record_failure(breaker, :test_provider)
      end

      # Circuit should be open
      assert {:error, :circuit_open} =
               MEV.CircuitBreaker.call(:test_provider, fn -> :ok end)

      # Clean up
      GenServer.stop(breaker)
    end
  end

  describe "Task Runner" do
    test "runs tasks in parallel", %{accounts: accounts} do
      from = Enum.at(accounts, 0)
      to = Enum.at(accounts, 1)

      # Create multiple bundles
      bundles =
        for i <- 0..2 do
          tx =
            TestHelpers.create_test_transaction(
              from: from.address,
              to: to.address,
              value: 1_000_000_000_000_000,
              nonce: i,
              private_key: from.private_key
            )

          {:ok, bundle} = MEV.create_bundle([tx], 100 + i)
          bundle
        end

      # Run parallel simulation (mock)
      results =
        MEV.TaskRunner.parallel_map(
          bundles,
          fn bundle ->
            # Simulate processing
            Process.sleep(10)
            {:ok, bundle.block_number}
          end,
          max_concurrency: 3
        )

      assert length(results) == 3

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  # Mock provider for testing
  defmodule MockProvider do
    @behaviour Ethers.MEV.Provider

    def send_bundle(_bundle, _opts), do: {:ok, "0xmock_hash"}
    def simulate_bundle(_bundle, _opts), do: {:ok, %{results: []}}
    def get_bundle_status(_hash, _block, _opts), do: {:ok, %{is_simulated: true}}
    def get_user_stats(_address, _opts), do: {:ok, %{}}
    def cancel_bundle(_uuid, _opts), do: {:ok, :cancelled}
    def send_private_transaction(_tx, _opts), do: {:ok, "0xtx_hash"}
  end
end
