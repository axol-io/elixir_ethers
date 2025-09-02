defmodule Ethers.MEVTest do
  use ExUnit.Case, async: true

  alias Ethers.MEV
  alias Ethers.MEV.Bundle

  describe "create_bundle/2" do
    test "creates a bundle with valid parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:ok, bundle} = MEV.create_bundle(transactions, block_number: 12_345)
      assert %Bundle{} = bundle
      assert bundle.transactions == transactions
      assert bundle.block_number == 12_345
    end

    test "creates a bundle with optional parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:ok, bundle} =
               MEV.create_bundle(transactions,
                 block_number: 12_345,
                 min_timestamp: 1_234_567_890,
                 max_timestamp: 1_234_567_900,
                 reverting_tx_hashes: ["0xabc"],
                 replacement_uuid: "test-uuid"
               )

      assert bundle.min_timestamp == 1_234_567_890
      assert bundle.max_timestamp == 1_234_567_900
      assert bundle.reverting_tx_hashes == ["0xabc"]
      assert bundle.replacement_uuid == "test-uuid"
    end

    test "returns error when block_number is missing" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:error, :missing_block_number} = MEV.create_bundle(transactions)
    end

    test "returns error for empty transactions" do
      assert {:error, :empty_bundle} = MEV.create_bundle([], block_number: 12_345)
    end
  end

  describe "create_bundle!/2" do
    test "creates a bundle with valid parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      bundle = MEV.create_bundle!(transactions, block_number: 12_345)
      assert %Bundle{} = bundle
      assert bundle.transactions == transactions
    end

    test "raises on missing block_number" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert_raise ArgumentError, ~r/Bundle creation failed/, fn ->
        MEV.create_bundle!(transactions)
      end
    end
  end

  describe "pipeline functions" do
    test "bundle/2 creates a bundle" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      bundle = MEV.bundle(transactions, block_number: 12_345)
      assert %Bundle{} = bundle
      assert bundle.transactions == transactions
      assert bundle.block_number == 12_345
    end

    test "with_reverting_hashes/2 adds reverting hashes" do
      bundle =
        ["0x" <> String.duplicate("ab", 32)]
        |> MEV.bundle(block_number: 12_345)
        |> MEV.with_reverting_hashes(["0xabc", "0xdef"])

      assert bundle.reverting_tx_hashes == ["0xabc", "0xdef"]
    end

    test "with_timestamp_range/3 sets timestamps" do
      bundle =
        ["0x" <> String.duplicate("ab", 32)]
        |> MEV.bundle(block_number: 12_345)
        |> MEV.with_timestamp_range(1_234_567_890, 1_234_567_900)

      assert bundle.min_timestamp == 1_234_567_890
      assert bundle.max_timestamp == 1_234_567_900
    end

    test "with_replacement_uuid/2 sets UUID" do
      bundle =
        ["0x" <> String.duplicate("ab", 32)]
        |> MEV.bundle(block_number: 12_345)
        |> MEV.with_replacement_uuid("test-uuid-123")

      assert bundle.replacement_uuid == "test-uuid-123"
    end

    test "pipeline composition works correctly" do
      bundle =
        ["0x" <> String.duplicate("ab", 32), "0x" <> String.duplicate("cd", 32)]
        |> MEV.bundle(block_number: 12_345)
        |> MEV.with_reverting_hashes(["0xabc"])
        |> MEV.with_timestamp_range(1_234_567_890, 1_234_567_900)
        |> MEV.with_replacement_uuid("pipeline-uuid")

      assert %Bundle{} = bundle
      assert length(bundle.transactions) == 2
      assert bundle.block_number == 12_345
      assert bundle.reverting_tx_hashes == ["0xabc"]
      assert bundle.min_timestamp == 1_234_567_890
      assert bundle.max_timestamp == 1_234_567_900
      assert bundle.replacement_uuid == "pipeline-uuid"
    end
  end

  describe "provider functions without configured provider" do
    test "send_bundle/2 returns error when no provider configured" do
      bundle = create_test_bundle()

      assert {:error, :no_provider_configured} = MEV.send_bundle(bundle)
    end

    test "simulate_bundle/2 returns error when no provider configured" do
      bundle = create_test_bundle()

      assert {:error, :no_provider_configured} = MEV.simulate_bundle(bundle)
    end

    test "get_bundle_status/3 returns error when no provider configured" do
      assert {:error, :no_provider_configured} = MEV.get_bundle_status("0xhash", 12_345)
    end

    test "cancel_bundle/2 returns error when no provider configured" do
      assert {:error, :no_provider_configured} = MEV.cancel_bundle("0xhash")
    end
  end

  describe "mock provider integration" do
    defmodule MockProvider do
      @behaviour Ethers.MEV.Provider

      @impl true
      def send_bundle(_bundle, _opts), do: {:ok, "0xmock_bundle_hash"}

      @impl true
      def simulate_bundle(_bundle, _opts) do
        {:ok, %{results: [], totalGasUsed: 21_000}}
      end

      @impl true
      def get_bundle_status(_hash, _block, _opts) do
        {:ok, %{status: "pending"}}
      end

      @impl true
      def cancel_bundle(_hash, _opts), do: {:ok, :cancelled}

      @impl true
      def get_user_stats(_address, _opts) do
        {:ok, %{bundles_submitted: 10}}
      end
    end

    test "send_bundle/2 works with mock provider" do
      bundle = create_test_bundle()

      assert {:ok, "0xmock_bundle_hash"} = MEV.send_bundle(bundle, provider: MockProvider)
    end

    test "simulate_bundle/2 works with mock provider" do
      bundle = create_test_bundle()

      assert {:ok, result} = MEV.simulate_bundle(bundle, provider: MockProvider)
      assert result.totalGasUsed == 21_000
    end

    test "simulate/2 pipeline function works with mock provider" do
      bundle = create_test_bundle()

      result = MEV.simulate(bundle, provider: MockProvider)
      assert result.totalGasUsed == 21_000
    end

    test "send/2 pipeline function works with mock provider" do
      bundle = create_test_bundle()

      hash = MEV.send(bundle, provider: MockProvider)
      assert hash == "0xmock_bundle_hash"
    end
  end

  # Helper functions

  defp create_test_bundle do
    MEV.create_bundle!(
      ["0x" <> String.duplicate("ab", 32)],
      block_number: 12_345
    )
  end
end
