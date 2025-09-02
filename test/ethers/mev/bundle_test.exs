defmodule Ethers.MEV.BundleTest do
  use ExUnit.Case, async: true

  alias Ethers.MEV.Bundle

  describe "new/1" do
    test "creates a bundle with valid parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32), "0x" <> String.duplicate("cd", 32)]

      assert {:ok, bundle} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: 12_345
               })

      assert bundle.transactions == transactions
      assert bundle.block_number == 12_345
      assert bundle.min_timestamp == nil
      assert bundle.max_timestamp == nil
      assert bundle.reverting_tx_hashes == nil
      assert bundle.replacement_uuid == nil
    end

    test "creates a bundle with all optional parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:ok, bundle} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: 12_345,
                 min_timestamp: 1_234_567_890,
                 max_timestamp: 1_234_567_900,
                 reverting_tx_hashes: ["0xabc", "0xdef"],
                 replacement_uuid: "test-uuid"
               })

      assert bundle.min_timestamp == 1_234_567_890
      assert bundle.max_timestamp == 1_234_567_900
      assert bundle.reverting_tx_hashes == ["0xabc", "0xdef"]
      assert bundle.replacement_uuid == "test-uuid"
    end

    test "returns error for empty transaction list" do
      assert {:error, :empty_bundle} =
               Bundle.new(%{
                 transactions: [],
                 block_number: 12_345
               })
    end

    test "returns error for missing transactions" do
      assert {:error, :empty_bundle} =
               Bundle.new(%{
                 block_number: 12_345
               })
    end

    test "returns error for invalid block number" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:error, :invalid_block_number} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: 0
               })

      assert {:error, :invalid_block_number} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: -1
               })

      assert {:error, :invalid_block_number} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: "not a number"
               })
    end

    test "returns error for invalid timestamp range" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:error, :invalid_timestamp_range} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: 12_345,
                 min_timestamp: 1_234_567_900,
                 max_timestamp: 1_234_567_890
               })
    end

    test "normalizes transaction hashes without 0x prefix" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      assert {:ok, bundle} =
               Bundle.new(%{
                 transactions: transactions,
                 block_number: 12_345,
                 reverting_tx_hashes: ["abc", "def"]
               })

      assert bundle.reverting_tx_hashes == ["0xabc", "0xdef"]
    end
  end

  describe "new!/1" do
    test "creates a bundle with valid parameters" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      bundle =
        Bundle.new!(%{
          transactions: transactions,
          block_number: 12_345
        })

      assert bundle.transactions == transactions
      assert bundle.block_number == 12_345
    end

    test "raises on invalid parameters" do
      assert_raise ArgumentError, ~r/Failed to create bundle/, fn ->
        Bundle.new!(%{
          transactions: [],
          block_number: 12_345
        })
      end
    end
  end

  describe "add_transaction/2" do
    test "adds a transaction to the bundle" do
      transactions = ["0x" <> String.duplicate("ab", 32)]

      bundle =
        Bundle.new!(%{
          transactions: transactions,
          block_number: 12_345
        })

      new_tx = "0x" <> String.duplicate("ef", 32)
      updated_bundle = Bundle.add_transaction(bundle, new_tx)

      assert length(updated_bundle.transactions) == 2
      assert List.last(updated_bundle.transactions) == new_tx
    end
  end

  describe "set_block_target/3" do
    test "sets the block target" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.set_block_target(bundle, 99_999)
      assert updated_bundle.block_number == 99_999
    end

    test "sets block target with max block" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.set_block_target(bundle, 99_999, 100_010)
      assert updated_bundle.block_number == 99_999
      assert Map.get(updated_bundle, :max_block) == 100_010
    end
  end

  describe "set_timing_constraints/3" do
    test "sets timing constraints" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.set_timing_constraints(bundle, 1_234_567_890, 1_234_567_900)
      assert updated_bundle.min_timestamp == 1_234_567_890
      assert updated_bundle.max_timestamp == 1_234_567_900
    end

    test "allows nil timestamps" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.set_timing_constraints(bundle, nil, 1_234_567_900)
      assert updated_bundle.min_timestamp == nil
      assert updated_bundle.max_timestamp == 1_234_567_900
    end
  end

  describe "allow_reverts/2" do
    test "sets reverting transaction hashes" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.allow_reverts(bundle, ["0xabc", "0xdef"])
      assert updated_bundle.reverting_tx_hashes == ["0xabc", "0xdef"]
    end

    test "normalizes hashes without 0x prefix" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.allow_reverts(bundle, ["abc", "def"])
      assert updated_bundle.reverting_tx_hashes == ["0xabc", "0xdef"]
    end

    test "allows nil to clear reverting hashes" do
      bundle =
        create_test_bundle()
        |> Bundle.allow_reverts(["0xabc"])

      updated_bundle = Bundle.allow_reverts(bundle, nil)
      assert updated_bundle.reverting_tx_hashes == nil
    end
  end

  describe "set_replacement_uuid/2" do
    test "sets replacement UUID" do
      bundle = create_test_bundle()

      updated_bundle = Bundle.set_replacement_uuid(bundle, "test-uuid-123")
      assert updated_bundle.replacement_uuid == "test-uuid-123"
    end

    test "allows nil to clear UUID" do
      bundle =
        create_test_bundle()
        |> Bundle.set_replacement_uuid("test-uuid")

      updated_bundle = Bundle.set_replacement_uuid(bundle, nil)
      assert updated_bundle.replacement_uuid == nil
    end
  end

  describe "encode/1" do
    test "encodes a basic bundle" do
      bundle =
        Bundle.new!(%{
          transactions: ["0xabcd", "0xef01"],
          block_number: 12_345
        })

      assert {:ok, encoded} = Bundle.encode(bundle)
      assert encoded.txs == ["0xabcd", "0xef01"]
      assert encoded.blockNumber == "0x3039"
    end

    test "encodes a bundle with all fields" do
      bundle =
        Bundle.new!(%{
          transactions: ["0xabcd"],
          block_number: 12_345,
          min_timestamp: 1_234_567_890,
          max_timestamp: 1_234_567_900,
          reverting_tx_hashes: ["0xabc123"],
          replacement_uuid: "test-uuid"
        })

      assert {:ok, encoded} = Bundle.encode(bundle)
      assert encoded.txs == ["0xabcd"]
      assert encoded.blockNumber == "0x3039"
      assert encoded.minTimestamp == 1_234_567_890
      assert encoded.maxTimestamp == 1_234_567_900
      assert encoded.revertingTxHashes == ["0xabc123"]
      assert encoded.replacementUuid == "test-uuid"
    end

    test "omits nil fields from encoding" do
      bundle =
        Bundle.new!(%{
          transactions: ["0xabcd"],
          block_number: 12_345
        })

      assert {:ok, encoded} = Bundle.encode(bundle)
      refute Map.has_key?(encoded, :minTimestamp)
      refute Map.has_key?(encoded, :maxTimestamp)
      refute Map.has_key?(encoded, :revertingTxHashes)
      refute Map.has_key?(encoded, :replacementUuid)
    end

    test "handles transactions without 0x prefix" do
      bundle =
        Bundle.new!(%{
          transactions: [String.duplicate("ab", 32)],
          block_number: 12_345
        })

      assert {:ok, encoded} = Bundle.encode(bundle)
      assert [tx] = encoded.txs
      assert String.starts_with?(tx, "0x")
    end
  end

  # Helper functions

  defp create_test_bundle do
    Bundle.new!(%{
      transactions: ["0x" <> String.duplicate("ab", 32)],
      block_number: 12_345
    })
  end
end
