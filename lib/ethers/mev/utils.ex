defmodule Ethers.MEV.Utils do
  import Bitwise

  @moduledoc """
  Shared utility functions for MEV modules.

  Consolidates common patterns used across MEV implementation.
  """

  @doc """
  Generates a UUID v4 string.

  ## Examples

      iex> uuid = Ethers.MEV.Utils.generate_uuid()
      iex> String.match?(uuid, ~r/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/)
      true
  """
  @spec generate_uuid() :: String.t()
  def generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> to_string()
  end

  @doc """
  Conditionally puts a key-value pair in a map.

  If the value is nil, returns the map unchanged.

  ## Examples

      iex> Ethers.MEV.Utils.maybe_put(%{a: 1}, :b, 2)
      %{a: 1, b: 2}
      
      iex> Ethers.MEV.Utils.maybe_put(%{a: 1}, :b, nil)
      %{a: 1}
  """
  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Calculates hit rate percentage from hits and misses.

  ## Examples

      iex> Ethers.MEV.Utils.calculate_hit_rate(%{hits: 75, misses: 25})
      75.0
      
      iex> Ethers.MEV.Utils.calculate_hit_rate(%{hits: 0, misses: 0})
      0.0
  """
  @spec calculate_hit_rate(map()) :: float()
  def calculate_hit_rate(%{hits: hits, misses: misses}) when hits + misses > 0 do
    hits / (hits + misses) * 100
  end

  def calculate_hit_rate(_), do: 0.0

  @doc """
  Gets a process via Registry lookup.

  Returns the pid if found, otherwise returns a via tuple for registration.

  ## Examples

      iex> Ethers.MEV.Utils.get_process_via_registry(:my_process)
      {:via, Registry, {Ethers.MEV.Registry, :my_process}}
  """
  @spec get_process_via_registry(atom()) :: pid() | {:via, Registry, tuple()}
  def get_process_via_registry(name) do
    case Registry.lookup(Ethers.MEV.Registry, name) do
      [{pid, _}] -> pid
      [] -> {:via, Registry, {Ethers.MEV.Registry, name}}
    end
  end

  @doc """
  Emits a telemetry event with standardized format.

  ## Examples

      iex> Ethers.MEV.Utils.emit_telemetry([:mev, :bundle, :submitted], %{count: 1}, %{bundle_hash: "0x123"})
      :ok
  """
  @spec emit_telemetry(list(atom()), map(), map()) :: :ok
  def emit_telemetry(event_name, measurements, metadata) do
    :telemetry.execute(
      [:ethers | event_name],
      measurements,
      metadata
    )

    :ok
  end

  @doc """
  Parses RPC error responses in a standardized way.

  ## Examples

      iex> Ethers.MEV.Utils.parse_rpc_error(%{"code" => -32000, "message" => "bundle not found"})
      {:error, :bundle_not_found}
  """
  @spec parse_rpc_error(map()) :: {:error, atom() | term()}
  def parse_rpc_error(%{"message" => message, "code" => code}) do
    error_atom =
      case message do
        "bundle not found" -> :bundle_not_found
        "invalid signature" -> :invalid_signature
        "block already passed" -> :block_passed
        "rate limited" -> :rate_limited
        _ -> {:rpc_error, code, message}
      end

    {:error, error_atom}
  end

  def parse_rpc_error(%{"message" => message}) do
    {:error, {:rpc_error, message}}
  end

  def parse_rpc_error(error) do
    {:error, {:unknown_error, error}}
  end

  @doc """
  Handles standard RPC response patterns.

  ## Examples

      iex> Ethers.MEV.Utils.handle_rpc_response(%{"result" => %{"value" => 1}}, &(&1))
      {:ok, %{"value" => 1}}
      
      iex> Ethers.MEV.Utils.handle_rpc_response(%{"error" => %{"message" => "failed"}}, &(&1))
      {:error, {:rpc_error, "failed"}}
  """
  @spec handle_rpc_response(map(), function()) :: {:ok, any()} | {:error, any()}
  def handle_rpc_response(%{"result" => result}, parser) when is_function(parser, 1) do
    {:ok, parser.(result)}
  end

  def handle_rpc_response(%{"error" => error}, _parser) do
    parse_rpc_error(error)
  end

  def handle_rpc_response(_, _parser) do
    {:error, :invalid_response}
  end

  @doc """
  Builds configuration options with defaults.

  ## Examples

      iex> defaults = %{timeout: 5000, retries: 3}
      iex> Ethers.MEV.Utils.build_config([timeout: 10000], defaults)
      %{timeout: 10000, retries: 3}
  """
  @spec build_config(keyword(), map()) :: map()
  def build_config(opts, defaults) do
    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      Map.put(acc, key, Keyword.get(opts, key, default))
    end)
  end

  @doc """
  Validates required options are present.

  ## Examples

      iex> Ethers.MEV.Utils.validate_required_opts([key: "value"], [:key])
      :ok
      
      iex> Ethers.MEV.Utils.validate_required_opts([], [:key])
      {:error, "Missing required option: key"}
  """
  @spec validate_required_opts(keyword(), list(atom())) :: :ok | {:error, String.t()}
  def validate_required_opts(opts, required) do
    missing = Enum.filter(required, &(not Keyword.has_key?(opts, &1)))

    case missing do
      [] -> :ok
      [field] -> {:error, "Missing required option: #{field}"}
      fields -> {:error, "Missing required options: #{Enum.join(fields, ", ")}"}
    end
  end

  @doc """
  Extracts transaction field safely.

  ## Examples

      iex> Ethers.MEV.Utils.get_transaction_field(%{nonce: 5}, :nonce)
      {:ok, 5}
      
      iex> Ethers.MEV.Utils.get_transaction_field(%{}, :nonce)
      {:error, :no_nonce}
  """
  @spec get_transaction_field(map() | binary(), atom()) :: {:ok, any()} | {:error, atom()}
  def get_transaction_field(tx, _field) when is_binary(tx) do
    {:error, :raw_transaction}
  end

  def get_transaction_field(tx, field) when is_map(tx) do
    case Map.get(tx, field) do
      nil -> {:error, :"no_#{field}"}
      value -> {:ok, value}
    end
  end

  def get_transaction_field(_, field) do
    {:error, :"invalid_transaction_for_#{field}"}
  end

  @doc """
  Formats error for consistent logging.

  ## Examples

      iex> Ethers.MEV.Utils.format_error({:error, :timeout})
      "Error: timeout"
      
      iex> Ethers.MEV.Utils.format_error({:error, {:rpc_error, -32000, "failed"}})
      "RPC Error (-32000): failed"
  """
  @spec format_error({:error, any()}) :: String.t()
  def format_error({:error, :timeout}), do: "Error: timeout"
  def format_error({:error, :rate_limited}), do: "Error: rate limited"
  def format_error({:error, {:rpc_error, code, msg}}), do: "RPC Error (#{code}): #{msg}"
  def format_error({:error, {:rpc_error, msg}}), do: "RPC Error: #{msg}"
  def format_error({:error, reason}), do: "Error: #{inspect(reason)}"

  @doc """
  Wraps a function call with timeout.

  ## Examples

      iex> Ethers.MEV.Utils.with_timeout(fn -> :ok end, 1000)
      {:ok, :ok}
  """
  @spec with_timeout(function(), non_neg_integer()) :: {:ok, any()} | {:error, :timeout}
  def with_timeout(fun, timeout) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end

  @doc """
  Retries a function with exponential backoff.

  ## Examples

      iex> Ethers.MEV.Utils.retry_with_backoff(fn -> {:ok, 1} end, 3)
      {:ok, 1}
  """
  @spec retry_with_backoff(function(), non_neg_integer(), non_neg_integer()) :: any()
  def retry_with_backoff(fun, retries, delay \\ 100)

  def retry_with_backoff(fun, 0, _delay) do
    fun.()
  end

  def retry_with_backoff(fun, retries, delay) do
    case fun.() do
      {:error, _} when retries > 0 ->
        Process.sleep(delay)
        retry_with_backoff(fun, retries - 1, delay * 2)

      result ->
        result
    end
  end
end
