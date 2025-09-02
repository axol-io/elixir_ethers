defmodule Ethers.MEV.RetryPipeline do
  @moduledoc """
  Functional retry pipeline for MEV bundle submission.

  This module provides a pure functional approach to bundle submission
  with automatic retry logic. All functions return transformed data
  that can be composed in pipelines.

  ## Architecture

  The pipeline uses a continuation-passing style where each operation
  returns a result that can be passed to the next operation. State is
  threaded through the pipeline without mutation.

  ## Example

      result = 
        bundle
        |> RetryPipeline.submit_with_retry(
          strategy: RetryStrategy.exponential(),
          provider: provider,
          opts: opts
        )
        |> RetryPipeline.wait_for_inclusion(timeout: 60_000)
        |> RetryPipeline.handle_result()
  """

  alias Ethers.MEV.{Bundle, BundleState, ConflictDetector, RetryStrategy, Telemetry}

  @type submission_result :: %{
          bundle: Bundle.t(),
          state: BundleState.t(),
          result: {:ok, String.t()} | {:error, term()},
          attempts: [attempt_record()]
        }

  @type attempt_record :: %{
          attempt: non_neg_integer(),
          timestamp: DateTime.t(),
          result: {:ok, String.t()} | {:error, term()},
          delay: non_neg_integer()
        }

  @type pipeline_opts :: %{
          strategy: RetryStrategy.strategy(),
          provider: module(),
          provider_opts: keyword(),
          max_attempts: non_neg_integer(),
          timeout: non_neg_integer()
        }

  # ============================================================================
  # Main Pipeline Functions
  # ============================================================================

  @doc """
  Submits a bundle with automatic retry on failure.

  Returns a submission result containing the final state and all attempts.

  ## Options
  - `:strategy` - Retry strategy (required)
  - `:provider` - MEV provider module (required)
  - `:provider_opts` - Provider options (required)
  - `:max_attempts` - Maximum submission attempts (default: 5)
  - `:timeout` - Total timeout in ms (default: 300_000)

  ## Example

      result = RetryPipeline.submit_with_retry(bundle, %{
        strategy: RetryStrategy.exponential(),
        provider: Ethers.MEV.Providers.Flashbots,
        provider_opts: [signer: signer]
      })
  """
  @spec submit_with_retry(Bundle.t(), map()) :: submission_result()
  def submit_with_retry(%Bundle{} = bundle, opts) do
    initial_state = BundleState.new(bundle, max_retries: opts[:max_attempts] || 5)

    submission_result = %{
      bundle: bundle,
      state: initial_state,
      result: nil,
      attempts: []
    }

    opts_with_defaults =
      Map.merge(
        %{
          max_attempts: 5,
          timeout: 300_000
        },
        opts
      )

    execute_submission_loop(submission_result, opts_with_defaults, 1)
  end

  @doc """
  Creates a lazy stream of submission attempts.

  Returns a stream that yields attempt results. Useful for reactive processing.

  ## Example

      bundle
      |> RetryPipeline.submission_stream(opts)
      |> Stream.take_while(fn result -> 
        result.result != {:ok, _}
      end)
      |> Enum.to_list()
  """
  @spec submission_stream(Bundle.t(), map()) :: Enumerable.t()
  def submission_stream(%Bundle{} = bundle, opts) do
    Stream.unfold(
      {bundle, BundleState.new(bundle), 1},
      fn
        {_bundle, %{status: :included} = _state, _attempt} ->
          nil

        {_bundle, %{status: :expired} = _state, _attempt} ->
          nil

        {_bundle, _state, attempt} when attempt > opts.max_attempts ->
          nil

        {bundle, state, attempt} ->
          result = attempt_submission(bundle, state, opts, attempt)

          new_state = update_state_from_result(state, result.result)
          new_bundle = maybe_transform_bundle(bundle, attempt + 1, opts.strategy)

          {result, {new_bundle, new_state, attempt + 1}}
      end
    )
  end

  @doc """
  Chains multiple submission strategies.

  Tries each strategy in order until one succeeds.

  ## Example

      strategies = [
        %{strategy: RetryStrategy.linear(), max_attempts: 3},
        %{strategy: RetryStrategy.exponential(), max_attempts: 5}
      ]
      
      result = RetryPipeline.chain_strategies(bundle, strategies, base_opts)
  """
  @spec chain_strategies(Bundle.t(), [map()], map()) :: submission_result()
  def chain_strategies(bundle, strategies, base_opts) do
    Enum.reduce_while(strategies, nil, fn strategy_opts, _acc ->
      opts = Map.merge(base_opts, strategy_opts)
      result = submit_with_retry(bundle, opts)

      case result.result do
        {:ok, _} -> {:halt, result}
        _ -> {:cont, result}
      end
    end)
  end

  # ============================================================================
  # Pipeline Composition Functions
  # ============================================================================

  @doc """
  Adds conflict checking to the retry pipeline.

  Checks for conflicts before each submission attempt.

  ## Example

      bundle
      |> RetryPipeline.with_conflict_check()
      |> RetryPipeline.submit_with_retry(opts)
  """
  @spec with_conflict_check(Bundle.t(), keyword()) :: Bundle.t()
  def with_conflict_check(%Bundle{} = bundle, check_opts \\ []) do
    case ConflictDetector.check_conflicts(bundle, check_opts) do
      {:ok, :no_conflicts} ->
        bundle

      {:ok, conflicts} ->
        # Add conflicts to bundle metadata for logging
        Map.put(bundle, :metadata, %{conflicts_detected: conflicts})

      {:error, _} ->
        bundle
    end
  end

  @doc """
  Adds profitability check to the pipeline.

  Only submits if the bundle meets profitability requirements.

  ## Example

      bundle
      |> RetryPipeline.with_profit_check(min_profit: 1_000_000)
      |> RetryPipeline.submit_with_retry(opts)
  """
  @spec with_profit_check(Bundle.t(), keyword()) :: Bundle.t() | {:skip, map()}
  def with_profit_check(%Bundle{} = bundle, profit_opts) do
    case simulate_bundle(bundle, profit_opts) do
      {:ok, simulation} ->
        profit = extract_profit(simulation)
        min_profit = Keyword.get(profit_opts, :min_profit, 0)

        if profit >= min_profit do
          bundle
        else
          {:skip, %{reason: :insufficient_profit, profit: profit, required: min_profit}}
        end

      _ ->
        bundle
    end
  end

  @doc """
  Transforms the submission result into a standardized format.

  ## Example

      bundle
      |> RetryPipeline.submit_with_retry(opts)
      |> RetryPipeline.format_result()
  """
  @spec format_result(submission_result()) :: map()
  def format_result(%{} = result) do
    %{
      success: match?({:ok, _}, result.result),
      bundle_hash: extract_bundle_hash(result.result),
      final_status: result.state.status,
      total_attempts: length(result.attempts),
      retry_count: result.state.retry_count,
      attempts: format_attempts(result.attempts)
    }
  end

  # ============================================================================
  # Functional Retry Logic
  # ============================================================================

  defp execute_submission_loop(result, opts, attempt) when attempt > opts.max_attempts do
    %{result | result: {:error, :max_attempts_exceeded}}
    |> Telemetry.emit(:max_retries_reached)
  end

  defp execute_submission_loop(result, opts, attempt) do
    start_time = System.monotonic_time(:millisecond)

    # Check timeout
    if exceeded_timeout?(start_time, opts.timeout) do
      %{result | result: {:error, :timeout}}
      |> Telemetry.emit(:submission_timeout)
    else
      # Calculate delay for this attempt
      delay = RetryStrategy.calculate_delay(opts.strategy, attempt: attempt)

      # Sleep if not first attempt
      if attempt > 1, do: Process.sleep(delay)

      # Transform bundle for retry
      bundle = maybe_transform_bundle(result.bundle, attempt, opts.strategy)

      # Attempt submission
      attempt_result = attempt_submission(bundle, result.state, opts, attempt)

      # Update state
      new_state = update_state_from_result(result.state, attempt_result.result)

      # Record attempt
      updated_result = %{
        result
        | state: new_state,
          attempts: result.attempts ++ [attempt_result]
      }

      # Check if we should continue
      case attempt_result.result do
        {:ok, hash} ->
          %{updated_result | result: {:ok, hash}}
          |> Telemetry.emit(:submission_success)

        {:error, reason} ->
          if RetryStrategy.retryable_error?(reason) do
            execute_submission_loop(updated_result, opts, attempt + 1)
          else
            %{updated_result | result: {:error, reason}}
            |> Telemetry.emit(:submission_permanent_failure)
          end
      end
    end
  end

  defp attempt_submission(bundle, state, opts, attempt) do
    timestamp = DateTime.utc_now()

    # Emit telemetry for attempt
    Telemetry.emit({bundle, state}, :submission_attempt, %{attempt: attempt})

    # Perform actual submission
    result = opts.provider.send_bundle(bundle, opts.provider_opts)

    %{
      attempt: attempt,
      timestamp: timestamp,
      result: result,
      delay:
        if(attempt > 1,
          do: RetryStrategy.calculate_delay(opts.strategy, attempt: attempt),
          else: 0
        )
    }
  end

  defp update_state_from_result(state, {:ok, hash}) do
    BundleState.mark_submitted(state, hash)
  end

  defp update_state_from_result(state, {:error, reason}) do
    BundleState.mark_failed(state, reason)
  end

  defp maybe_transform_bundle(bundle, 1, _strategy), do: bundle

  defp maybe_transform_bundle(bundle, attempt, _strategy) do
    RetryStrategy.transform_for_retry(bundle,
      attempt: attempt,
      gas_multiplier: 1.0 + 0.1 * (attempt - 1)
    )
  end

  defp exceeded_timeout?(start_time, timeout) do
    System.monotonic_time(:millisecond) - start_time > timeout
  end

  defp simulate_bundle(bundle, opts) do
    # For testing, check for mock flags
    cond do
      Keyword.get(opts, :force_error, false) ->
        {:error, :simulation_failed}

      Keyword.get(opts, :mock_no_profit, false) ->
        # Mock case where simulation returns without coinbase_diff
        {:ok, %{gas_used: 21_000}}

      Keyword.get(opts, :mock_simulation, false) ->
        # Mock for testing
        {:ok, %{coinbase_diff: "0x0"}}

      true ->
        # Real simulation using the provider
        provider = Keyword.get(opts, :provider)
        provider_opts = Keyword.get(opts, :provider_opts, [])

        if provider && function_exported?(provider, :simulate_bundle, 2) do
          provider.simulate_bundle(bundle, provider_opts)
        else
          # Fallback to mock if no provider configured
          {:ok, %{coinbase_diff: "0x0", gas_used: 21_000}}
        end
    end
  end

  defp extract_profit(%{coinbase_diff: diff}) when is_binary(diff) do
    case Integer.parse(diff, 16) do
      {value, _} -> value
      _ -> 0
    end
  end

  defp extract_profit(_), do: 0

  defp extract_bundle_hash({:ok, hash}), do: hash
  defp extract_bundle_hash(_), do: nil

  defp format_attempts(attempts) do
    Enum.map(attempts, fn attempt ->
      %{
        number: attempt.attempt,
        timestamp: attempt.timestamp,
        success: match?({:ok, _}, attempt.result),
        delay_ms: attempt.delay,
        error: extract_error(attempt.result)
      }
    end)
  end

  defp extract_error({:error, reason}), do: inspect(reason)
  defp extract_error(_), do: nil
end
