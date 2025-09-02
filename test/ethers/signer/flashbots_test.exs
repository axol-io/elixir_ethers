defmodule Ethers.Signer.FlashbotsTest do
  use ExUnit.Case, async: true

  alias Ethers.Signer.Flashbots

  import Ethers, only: [keccak_module: 0]

  # Test vectors from Ethereum
  # Private key from Anvil default accounts
  @private_key Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80",
                 case: :upper
               )
  @expected_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  describe "sign_message/2" do
    test "signs a message with EIP-191 personal_sign format" do
      # Create a 32-byte message (keccak256 hash)
      message = keccak_module().hash_256("test message")

      assert {:ok, {address, signature}} = Flashbots.sign_message(message, @private_key)

      # Check address format
      assert String.downcase(address) == @expected_address
      assert String.starts_with?(signature, "0x")

      # Signature should be 65 bytes (130 hex chars + 0x prefix)
      assert String.length(signature) == 132
    end

    test "returns error for invalid message length" do
      # Message must be 32 bytes for Flashbots
      short_message = "too short"

      assert {:error, :invalid_message_length} =
               Flashbots.sign_message(short_message, @private_key)
    end

    test "produces deterministic signatures" do
      message = keccak_module().hash_256("deterministic test")

      {:ok, {address1, signature1}} = Flashbots.sign_message(message, @private_key)
      {:ok, {address2, signature2}} = Flashbots.sign_message(message, @private_key)

      assert address1 == address2
      assert signature1 == signature2
    end

    test "produces different signatures for different messages" do
      message1 = keccak_module().hash_256("message 1")
      message2 = keccak_module().hash_256("message 2")

      {:ok, {_, signature1}} = Flashbots.sign_message(message1, @private_key)
      {:ok, {_, signature2}} = Flashbots.sign_message(message2, @private_key)

      assert signature1 != signature2
    end
  end

  describe "create_personal_sign_hash/1" do
    test "creates EIP-191 formatted hash" do
      # 32-byte message
      message = String.duplicate(<<0>>, 32)

      assert {:ok, hash} = Flashbots.create_personal_sign_hash(message)
      assert byte_size(hash) == 32
    end

    test "includes correct EIP-191 prefix" do
      message = String.duplicate(<<0xFF>>, 32)

      {:ok, hash} = Flashbots.create_personal_sign_hash(message)

      # The hash should be different from just hashing the message directly
      direct_hash = keccak_module().hash_256(message)
      assert hash != direct_hash
    end

    test "rejects non-32-byte messages" do
      short_message = "too short"
      long_message = String.duplicate(<<0>>, 64)

      assert {:error, :invalid_message_length} =
               Flashbots.create_personal_sign_hash(short_message)

      assert {:error, :invalid_message_length} =
               Flashbots.create_personal_sign_hash(long_message)
    end
  end

  describe "integration with Ethers.Signer.Local" do
    test "Local signer can sign Flashbots requests" do
      message = keccak_module().hash_256("flashbots request")
      opts = [private_key: @private_key]

      assert {:ok, {address, signature}} =
               Ethers.Signer.Local.sign_flashbots_request(message, opts)

      assert String.downcase(address) == @expected_address
      assert String.starts_with?(signature, "0x")
    end

    test "Local signer handles hex-encoded private keys" do
      message = keccak_module().hash_256("flashbots request")
      hex_key = "0x" <> Base.encode16(@private_key, case: :lower)
      opts = [private_key: hex_key]

      assert {:ok, {address, _signature}} =
               Ethers.Signer.Local.sign_flashbots_request(message, opts)

      assert String.downcase(address) == @expected_address
    end

    test "Local signer returns error for missing private key" do
      message = keccak_module().hash_256("flashbots request")
      opts = []

      assert {:error, :no_private_key} =
               Ethers.Signer.Local.sign_flashbots_request(message, opts)
    end
  end

  describe "X-Flashbots-Signature header format" do
    test "produces correctly formatted signature for header" do
      # This tests that the output can be used directly in the header
      message = keccak_module().hash_256("{'jsonrpc':'2.0','method':'eth_sendBundle'}")

      {:ok, {address, signature}} = Flashbots.sign_message(message, @private_key)

      # Header should be: "address:signature"
      header_value = "#{address}:#{signature}"

      # Check format
      assert String.contains?(header_value, ":")
      parts = String.split(header_value, ":")
      assert length(parts) == 2

      [header_address, header_signature] = parts
      assert String.starts_with?(header_address, "0x")
      assert String.starts_with?(header_signature, "0x")
    end
  end

  describe "signature verification" do
    test "signature components are valid" do
      message = keccak_module().hash_256("verify me")

      {:ok, {_address, signature}} = Flashbots.sign_message(message, @private_key)

      # Remove 0x prefix
      sig_hex = String.slice(signature, 2..-1)
      sig_bytes = Base.decode16!(sig_hex, case: :mixed)

      # Signature should be 65 bytes: r (32) + s (32) + v (1)
      assert byte_size(sig_bytes) == 65

      # Extract components
      <<r::binary-size(32), s::binary-size(32), v::8>> = sig_bytes

      # v should be 27 or 28 for Ethereum signatures
      assert v in [27, 28]

      # r and s should be non-zero
      assert r != String.duplicate(<<0>>, 32)
      assert s != String.duplicate(<<0>>, 32)
    end
  end
end
