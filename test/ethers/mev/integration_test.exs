defmodule Ethers.MEV.IntegrationTest do
  @moduledoc """
  Integration tests for MEV functionality using Anvil.

  These tests require Anvil to be running and test the full
  MEV pipeline including bundle creation, simulation, and submission.
  """

  use ExUnit.Case, async: false

  alias Ethers.MEV
  alias Ethers.MEV.Bundle
  alias Ethers.MEV.TestHelpers
  alias Ethers.Transaction
  alias Ethers.Signer.Local

  @moduletag :integration
  @moduletag timeout: 60_000

  setup_all do
    # Ensure Anvil is running
    case System.cmd("pgrep", ["anvil"]) do
      {_, 0} ->
        :ok

      _ ->
        # Start Anvil in the background
        Task.start(fn ->
          System.cmd("anvil", ["--port", "8545", "--chain-id", "1"])
        end)

        Process.sleep(2000)
    end

    :ok
  end

  describe "bundle creation and validation" do
    test "creates a valid bundle from signed transactions" do
      # Get test accounts
      from_account = TestHelpers.get_test_account(0)
      to_account = TestHelpers.get_test_account(1)

      # Create a signed transaction
      tx = %Transaction.Legacy{
        nonce: 0,
        gas_price: 20_000_000_000,
        gas: 21_000,
        to: to_account.address,
        value: 1_000_000_000_000_000,
        input: "",
        chain_id: 1
      }

      {:ok, signed_tx} =
        Local.sign_transaction(tx,
          private_key: from_account.private_key,
          from: from_account.address
        )

      # Create bundle
      {:ok, bundle} =
        MEV.create_bundle([signed_tx],
          block_number: 100
        )

      assert %Bundle{} = bundle
      assert bundle.block_number == 100
      assert length(bundle.transactions) == 1
    end

    test "validates bundle constraints" do
      bundle =
        TestHelpers.create_test_bundle(
          transaction_count: 2,
          block_number: 100
        )

      # Add timing constraints
      bundle_with_timing =
        MEV.with_timestamp_range(
          bundle,
          1_000_000_000,
          2_000_000_000
        )

      assert bundle_with_timing.min_timestamp == 1_000_000_000
      assert bundle_with_timing.max_timestamp == 2_000_000_000
    end
  end

  describe "pipeline operations" do
    test "composes pipeline operations" do
      from_account = TestHelpers.get_test_account(0)
      to_account = TestHelpers.get_test_account(1)

      # Create transactions
      txs =
        for i <- 0..2 do
          TestHelpers.create_test_transaction(
            from: from_account.address,
            to: to_account.address,
            value: 1_000_000_000_000_000,
            nonce: i,
            private_key: from_account.private_key
          )
        end

      # Pipeline operations
      result =
        txs
        |> MEV.bundle(block_number: 100)
        |> MEV.with_reverting_hashes(["0xabc123"])
        |> MEV.with_replacement_uuid("test-uuid")

      assert result.block_number == 100
      assert result.reverting_tx_hashes == ["0xabc123"]
      assert result.replacement_uuid == "test-uuid"
      assert length(result.transactions) == 3
    end
  end

  describe "mock provider testing" do
    @tag :skip
    test "simulates bundle execution" do
      # This would test against a real provider
      # Skipped for now as we don't have a real Flashbots endpoint
      bundle = TestHelpers.create_test_bundle()

      {:ok, simulation} =
        MEV.simulate_bundle(bundle,
          provider: Ethers.MEV.Providers.Flashbots,
          signer: {Local, private_key: TestHelpers.get_test_account(0).private_key}
        )

      assert simulation
    end
  end

  describe "bundle monitoring" do
    test "monitors bundle status" do
      bundle = TestHelpers.create_test_bundle(block_number: 100)

      # Start monitor
      {:ok, monitor} =
        MEV.monitor_bundle(
          "0xtest_bundle_hash",
          bundle.block_number,
          provider: Ethers.MEV.Providers.Flashbots,
          provider_opts: [url: "http://localhost:8545"],
          check_interval: 100,
          max_wait: 2
        )

      # Check that monitor is running
      assert Process.alive?(monitor)

      # Stop monitor
      GenServer.stop(monitor)
    end
  end

  describe "conflict detection" do
    test "detects no conflicts for valid bundle" do
      bundle = TestHelpers.create_test_bundle()

      {:ok, result} =
        Ethers.MEV.ConflictDetector.check_conflicts(bundle,
          check_mempool: false,
          check_balance: false
        )

      assert result == :no_conflicts
    end
  end
end
