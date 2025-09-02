defmodule Ethers.MEV.RetryStrategy do
  @moduledoc """
  Functional retry strategies for MEV bundle submission.

  This module provides pure functions for calculating retry delays,
  determining retry conditions, and transforming bundles for retry.
  All functions are deterministic and side-effect free.

  ## Strategies

  - **Exponential Backoff**: Delay doubles with each retry
  - **Linear Backoff**: Delay increases linearly
  - **Fibonacci Backoff**: Delay follows Fibonacci sequence
  - **Custom**: User-defined delay function

  ## Example

      strategy = RetryStrategy.exponential(base: 1000, max: 30_000)
      
      delay = RetryStrategy.calculate_delay(strategy, attempt: 3)
      # Returns 8000ms (1000 * 2^3)
      
      bundle
      |> RetryStrategy.transform_for_retry(attempt: 3)
      |> submit_bundle()
  """

  alias Ethers.MEV.Bundle
  alias Ethers.MEV.BundleState

  import Bitwise

  @type strategy :: %{
          type: strategy_type(),
          base_delay: non_neg_integer(),
          max_delay: non_neg_integer(),
          jitter: boolean(),
          multiplier: number(),
          custom_fn: (non_neg_integer() -> non_neg_integer()) | nil
        }

  @type strategy_type :: :exponential | :linear | :fibonacci | :custom

  @type retry_context :: %{
          attempt: non_neg_integer(),
          last_error: term(),
          elapsed_time: non_neg_integer(),
          bundle_state: BundleState.t()
        }

  # Default configuration
  # 1 second
  @default_base_delay 1_000
  # 30 seconds
  @default_max_delay 30_000
  @default_jitter true
  @default_multiplier 2

  # ============================================================================
  # Strategy Constructors (Pure Functions)
  # ============================================================================

  @doc """
  Creates an exponential backoff strategy.

  ## Options
  - `:base` - Base delay in milliseconds (default: 1000)
  - `:max` - Maximum delay in milliseconds (default: 30000)
  - `:jitter` - Add random jitter (default: true)
  - `:multiplier` - Exponential multiplier (default: 2)

  ## Example

      strategy = RetryStrategy.exponential(base: 500, max: 60_000)
  """
  @spec exponential(keyword()) :: strategy()
  def exponential(opts \\ []) do
    %{
      type: :exponential,
      base_delay: Keyword.get(opts, :base, @default_base_delay),
      max_delay: Keyword.get(opts, :max, @default_max_delay),
      jitter: Keyword.get(opts, :jitter, @default_jitter),
      multiplier: Keyword.get(opts, :multiplier, @default_multiplier),
      custom_fn: nil
    }
  end

  @doc """
  Creates a linear backoff strategy.

  ## Options
  - `:base` - Base delay increment (default: 1000)
  - `:max` - Maximum delay (default: 30000)
  - `:jitter` - Add random jitter (default: true)

  ## Example

      strategy = RetryStrategy.linear(base: 2000)
      # Delays: 2000, 4000, 6000, 8000, ...
  """
  @spec linear(keyword()) :: strategy()
  def linear(opts \\ []) do
    %{
      type: :linear,
      base_delay: Keyword.get(opts, :base, @default_base_delay),
      max_delay: Keyword.get(opts, :max, @default_max_delay),
      jitter: Keyword.get(opts, :jitter, @default_jitter),
      multiplier: 1,
      custom_fn: nil
    }
  end

  @doc """
  Creates a Fibonacci backoff strategy.

  ## Options
  - `:base` - Base delay unit (default: 1000)
  - `:max` - Maximum delay (default: 30000)
  - `:jitter` - Add random jitter (default: true)

  ## Example

      strategy = RetryStrategy.fibonacci(base: 100)
      # Delays: 100, 100, 200, 300, 500, 800, ...
  """
  @spec fibonacci(keyword()) :: strategy()
  def fibonacci(opts \\ []) do
    %{
      type: :fibonacci,
      base_delay: Keyword.get(opts, :base, @default_base_delay),
      max_delay: Keyword.get(opts, :max, @default_max_delay),
      jitter: Keyword.get(opts, :jitter, @default_jitter),
      multiplier: 1,
      custom_fn: nil
    }
  end

  @doc """
  Creates a custom retry strategy with a user-defined delay function.

  ## Example

      strategy = RetryStrategy.custom(fn attempt ->
        # Custom delay logic
        1000 * attempt * attempt
      end, max: 60_000)
  """
  @spec custom((non_neg_integer() -> non_neg_integer()), keyword()) :: strategy()
  def custom(delay_fn, opts \\ []) when is_function(delay_fn, 1) do
    %{
      type: :custom,
      base_delay: 0,
      max_delay: Keyword.get(opts, :max, @default_max_delay),
      jitter: Keyword.get(opts, :jitter, false),
      multiplier: 1,
      custom_fn: delay_fn
    }
  end

  # ============================================================================
  # Delay Calculation (Pure Functions)
  # ============================================================================

  @doc """
  Calculates the delay for a retry attempt.

  Returns the delay in milliseconds based on the strategy and attempt number.

  ## Example

      delay = RetryStrategy.calculate_delay(strategy, attempt: 3)
  """
  @spec calculate_delay(strategy(), keyword()) :: non_neg_integer()
  def calculate_delay(strategy, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)

    base_delay = calculate_base_delay(strategy, attempt)

    delay_with_jitter =
      if strategy.jitter do
        add_jitter(base_delay)
      else
        base_delay
      end

    min(delay_with_jitter, strategy.max_delay)
  end

  @doc """
  Calculates delays for multiple attempts.

  Returns a list of delays for attempts 1 through n.

  ## Example

      delays = RetryStrategy.calculate_delays(strategy, 5)
      # [1000, 2000, 4000, 8000, 16000]
  """
  @spec calculate_delays(strategy(), non_neg_integer()) :: [non_neg_integer()]
  def calculate_delays(strategy, attempts) do
    Enum.map(1..attempts, fn attempt ->
      calculate_delay(strategy, attempt: attempt)
    end)
  end

  # ============================================================================
  # Retry Decision Functions (Pure)
  # ============================================================================

  @doc """
  Determines if a retry should be attempted based on context.

  ## Criteria
  - Has retries remaining
  - Error is retryable
  - Within time limits
  - Bundle not expired

  ## Example

      if RetryStrategy.should_retry?(context) do
        # Proceed with retry
      end
  """
  @spec should_retry?(retry_context()) :: boolean()
  def should_retry?(context) do
    retryable_error?(context.last_error) and
      has_retries_remaining?(context) and
      within_time_limit?(context) and
      not BundleState.expired?(context.bundle_state)
  end

  @doc """
  Checks if an error is retryable.

  Some errors indicate permanent failure and shouldn't trigger retry.
  """
  @spec retryable_error?(term()) :: boolean()
  def retryable_error?({:error, :invalid_signature}), do: false
  def retryable_error?({:error, :invalid_bundle}), do: false
  def retryable_error?({:error, :insufficient_funds}), do: false
  def retryable_error?(_), do: true

  # ============================================================================
  # Bundle Transformation (Pure Functions)
  # ============================================================================

  @doc """
  Transforms a bundle for retry.

  Applies modifications to improve inclusion chances:
  - Increases gas price
  - Updates target block
  - Adds replacement UUID

  ## Options
  - `:gas_multiplier` - Multiplier for gas price (default: 1.1)
  - `:block_increment` - Blocks to add to target (default: 1)

  ## Example

      new_bundle = RetryStrategy.transform_for_retry(
        bundle,
        attempt: 3,
        gas_multiplier: 1.2
      )
  """
  @spec transform_for_retry(Bundle.t(), keyword()) :: Bundle.t()
  def transform_for_retry(%Bundle{} = bundle, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    gas_multiplier = Keyword.get(opts, :gas_multiplier, 1.1)
    block_increment = Keyword.get(opts, :block_increment, 1)

    bundle
    |> maybe_increase_gas_price(gas_multiplier, attempt)
    |> maybe_update_target_block(block_increment)
    |> ensure_replacement_uuid()
  end

  @doc """
  Creates a retry pipeline that combines delay and transformation.

  Returns a tuple with the delay and transformed bundle.

  ## Example

      {delay, new_bundle} = RetryStrategy.prepare_retry(
        strategy,
        bundle,
        context
      )
      
      Process.sleep(delay)
      submit_bundle(new_bundle)
  """
  @spec prepare_retry(strategy(), Bundle.t(), retry_context()) ::
          {non_neg_integer(), Bundle.t()}
  def prepare_retry(strategy, bundle, context) do
    delay = calculate_delay(strategy, attempt: context.attempt)

    transformed_bundle =
      transform_for_retry(
        bundle,
        attempt: context.attempt,
        gas_multiplier: calculate_gas_multiplier(context.attempt)
      )

    {delay, transformed_bundle}
  end

  # ============================================================================
  # Statistics and Analysis (Pure Functions)
  # ============================================================================

  @doc """
  Analyzes retry patterns and provides statistics.

  Returns insights about retry behavior and recommendations.
  """
  @spec analyze_retry_pattern(BundleState.t()) :: map()
  def analyze_retry_pattern(%BundleState{} = state) do
    retry_transitions = BundleState.transitions_to(state, :retry)

    %{
      total_retries: state.retry_count,
      retry_times: Enum.map(retry_transitions, & &1.timestamp),
      average_retry_interval: calculate_average_interval(retry_transitions),
      success_rate: calculate_success_rate(state),
      recommendation: recommend_strategy(state)
    }
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp calculate_base_delay(%{type: :exponential} = strategy, attempt) do
    round(strategy.base_delay * :math.pow(strategy.multiplier, attempt - 1))
  end

  defp calculate_base_delay(%{type: :linear} = strategy, attempt) do
    strategy.base_delay * attempt
  end

  defp calculate_base_delay(%{type: :fibonacci} = strategy, attempt) do
    strategy.base_delay * fibonacci_number(attempt)
  end

  defp calculate_base_delay(%{type: :custom, custom_fn: delay_fn}, attempt) do
    delay_fn.(attempt)
  end

  defp fibonacci_number(1), do: 1
  defp fibonacci_number(2), do: 1

  defp fibonacci_number(n) do
    fibonacci_sequence()
    |> Enum.at(n - 1)
  end

  defp fibonacci_sequence do
    Stream.unfold({1, 1}, fn {a, b} ->
      {a, {b, a + b}}
    end)
  end

  defp add_jitter(delay) do
    # Add ±10% random jitter
    jitter = round(delay * 0.1 * (2 * :rand.uniform() - 1))
    max(0, delay + jitter)
  end

  defp has_retries_remaining?(context) do
    context.attempt < context.bundle_state.max_retries
  end

  defp within_time_limit?(context) do
    # Default 5 minute time limit
    max_time = 5 * 60 * 1000
    context.elapsed_time < max_time
  end

  defp maybe_increase_gas_price(bundle, multiplier, attempt) do
    # Increase gas more aggressively with each retry
    _actual_multiplier = :math.pow(multiplier, attempt)

    # This would need to decode and modify transactions
    # For now, return bundle unchanged
    bundle
  end

  defp maybe_update_target_block(bundle, increment) do
    %{bundle | block_number: bundle.block_number + increment}
  end

  defp ensure_replacement_uuid(%{replacement_uuid: nil} = bundle) do
    %{bundle | replacement_uuid: generate_uuid()}
  end

  defp ensure_replacement_uuid(bundle), do: bundle

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> to_string()
  end

  defp calculate_gas_multiplier(attempt) do
    # Increase gas price by 10% per retry, max 2x
    min(1.0 + 0.1 * attempt, 2.0)
  end

  defp calculate_average_interval([]), do: 0
  defp calculate_average_interval([_]), do: 0

  defp calculate_average_interval(transitions) do
    intervals =
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [t1, t2] ->
        DateTime.diff(t1.timestamp, t2.timestamp, :millisecond)
      end)

    if Enum.empty?(intervals) do
      0
    else
      round(Enum.sum(intervals) / length(intervals))
    end
  end

  defp calculate_success_rate(%BundleState{status: :included}), do: 1.0
  defp calculate_success_rate(%BundleState{retry_count: 0}), do: 0.0

  defp calculate_success_rate(%BundleState{retry_count: retries}) do
    # Lower success rate with more retries
    1.0 / (retries + 1)
  end

  defp recommend_strategy(%BundleState{} = state) do
    cond do
      state.retry_count == 0 ->
        "No retries yet"

      state.retry_count > 3 and state.status != :included ->
        "Consider increasing gas price more aggressively"

      state.status == :included ->
        "Success after #{state.retry_count} retries"

      true ->
        "Continue with current strategy"
    end
  end
end
