defmodule Ethers.Signer.Flashbots do
  @moduledoc """
  Flashbots-specific signing functionality for MEV bundle authentication.

  This module provides EIP-191 personal message signing as required by
  the Flashbots relay for authenticating bundle submissions.

  ## Signing Process

  1. The message (typically a JSON-RPC request body) is hashed with Keccak256
  2. The hash is signed using EIP-191 personal_sign format
  3. The signature is returned along with the signer's address

  ## Integration

  This module is designed to work with any signer that can perform
  ECDSA signatures, particularly `Ethers.Signer.Local`.
  """

  alias Ethers.Utils

  import Ethers, only: [keccak_module: 0, secp256k1_module: 0]

  @doc """
  Signs a message for Flashbots authentication using EIP-191.

  ## Parameters
  - `message` - The message to sign (typically keccak256 hash of request body)
  - `private_key` - The private key to sign with

  ## Returns
  - `{:ok, {address, signature}}` - Signer address and hex-encoded signature
  - `{:error, reason}` - Error if signing fails

  ## Example

      message_hash = ExKeccak.hash_256(json_rpc_body)
      {:ok, {address, signature}} = Flashbots.sign_message(message_hash, private_key)
      # Header: "X-Flashbots-Signature: \#{address}:\#{signature}"
  """
  @spec sign_message(binary(), binary()) ::
          {:ok, {address :: String.t(), signature :: String.t()}} | {:error, term()}
  def sign_message(message, private_key) when is_binary(message) and is_binary(private_key) do
    with {:ok, personal_sign_hash} <- create_personal_sign_hash(message),
         {:ok, {r, s, v}} <- sign_hash(personal_sign_hash, private_key),
         {:ok, address} <- recover_address(private_key),
         signature <- encode_signature(r, s, v) do
      {:ok, {address, signature}}
    end
  end

  @doc """
  Creates an EIP-191 personal sign hash for a message.

  This follows the Ethereum personal_sign standard:
  `\\x19Ethereum Signed Message:\\n<message_length><message>`

  ## Parameters
  - `message` - The message to hash (should be 32 bytes for Flashbots)

  ## Returns
  - `{:ok, hash}` - The EIP-191 formatted hash
  - `{:error, reason}` - Error if hashing fails
  """
  @spec create_personal_sign_hash(binary()) :: {:ok, binary()} | {:error, term()}
  def create_personal_sign_hash(message) when is_binary(message) do
    # EIP-191 personal sign format
    prefix = <<0x19, "Ethereum Signed Message:\n", "32">>

    # For Flashbots, message should be 32 bytes (keccak256 hash)
    if byte_size(message) != 32 do
      {:error, :invalid_message_length}
    else
      personal_message = prefix <> message
      hash = keccak_module().hash_256(personal_message)
      {:ok, hash}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp sign_hash(hash, private_key) do
    case secp256k1_module().sign(hash, private_key) do
      {:ok, {r, s, recovery_id}} ->
        # Convert recovery_id to Ethereum v value (27 or 28)
        v = recovery_id + 27
        {:ok, {r, s, v}}

      error ->
        {:error, {:signing_failed, error}}
    end
  end

  defp recover_address(private_key) do
    case secp256k1_module().create_public_key(private_key) do
      {:ok, public_key} ->
        address = public_key_to_address(public_key)
        {:ok, address}

      error ->
        {:error, {:public_key_derivation_failed, error}}
    end
  end

  defp public_key_to_address(public_key) do
    # Remove the first byte (0x04 prefix for uncompressed key)
    <<_::8, key::binary-size(64)>> = public_key

    # Take the last 20 bytes of the keccak256 hash
    <<_::binary-size(12), address::binary-size(20)>> = keccak_module().hash_256(key)

    Utils.hex_encode(address)
  end

  defp encode_signature(r, s, v) do
    # Encode signature as r || s || v (65 bytes total)
    signature = r <> s <> <<v>>
    Utils.hex_encode(signature)
  end
end

defmodule Ethers.Signer.Local.Flashbots do
  @moduledoc """
  Extension to Ethers.Signer.Local for Flashbots-specific signing.

  This module adds Flashbots authentication capabilities to the local signer.
  """

  @doc """
  Signs a Flashbots request with EIP-191 personal_sign.

  ## Parameters
  - `message` - The message to sign (keccak256 hash of request body)
  - `opts` - Options including `:private_key`

  ## Returns
  - `{:ok, {address, signature}}` - Tuple for X-Flashbots-Signature header
  - `{:error, reason}` - Error if signing fails
  """
  @spec sign_flashbots_request(binary(), keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def sign_flashbots_request(message, opts) when is_binary(message) do
    case Keyword.fetch(opts, :private_key) do
      {:ok, private_key} ->
        Ethers.Signer.Flashbots.sign_message(message, private_key)

      :error ->
        {:error, :missing_private_key}
    end
  end
end
