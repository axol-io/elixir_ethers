defmodule Ethers.MEV.TaskRunner do
  @moduledoc """
  Supervised task execution for MEV operations with functional composition.

  This module provides fault-tolerant concurrent execution of MEV tasks
  using Task.Supervisor. All operations are designed to be composed
  functionally while maintaining supervision benefits.

  ## Features

  - Supervised async execution
  - Functional task composition
  - Automatic resource cleanup
  - Telemetry integration
  - Rate limiting support

  ## Example

      # Async bundle submission
      task = TaskRunner.async_submit(bundle, opts)
      result = Task.await(task, 30_000)

      # Parallel bundle submissions
      results = TaskRunner.parallel_map(bundles, &submit_bundle/1)

      # Rate-limited execution
      TaskRunner.with_rate_limit(100, fn ->
        submit_bundle(bundle)
      end)
  """

  alias Ethers.MEV.{Bundle, RetryPipeline, RetryStrategy, Telemetry}

  @type task_result :: {:ok, any()} | {:error, term()}
  @type task_opts :: %{
          timeout: non_neg_integer(),
          max_concurrency: non_neg_integer(),
          telemetry: boolean()
        }

  # Default configuration
  @default_timeout 30_000
  @default_max_concurrency 10

  # ============================================================================
  # Public API - Async Operations
  # ============================================================================

  @doc """
  Submits a bundle asynchronously with supervision.

  Returns a Task that can be awaited or used with Task.yield.

  ## Options
  - `:timeout` - Task timeout in ms (default: 30000)
  - `:retry_strategy` - Retry strategy to use
  - `:telemetry` - Enable telemetry events (default: true)

  ## Example

      task = TaskRunner.async_submit(bundle,
        retry_strategy: RetryStrategy.exponential(),
        timeout: 60_000
      )

      case Task.await(task, 60_000) do
        {:ok, hash} -> IO.puts("Submitted: " <> hash)
        {:error, reason} -> IO.puts("Failed: " <> inspect(reason))
      end
  """
  @spec async_submit(Bundle.t(), keyword()) :: Task.t()
  def async_submit(%Bundle{} = bundle, opts \\ []) do
    task_opts = build_task_opts(opts)

    Task.Supervisor.async(
      get_task_supervisor(),
      fn ->
        with_telemetry(task_opts, :bundle_submission, fn ->
          submit_with_retry(bundle, opts)
        end)
      end,
      shutdown: task_opts.timeout
    )
  end

  @doc """
  Executes a function asynchronously with supervision.

  Wraps any function in supervised task execution.

  ## Example

      task = TaskRunner.async(fn ->
        expensive_computation()
      end, timeout: 60_000)
  """
  @spec async((-> any()), keyword()) :: Task.t()
  def async(fun, opts \\ []) when is_function(fun, 0) do
    task_opts = build_task_opts(opts)

    Task.Supervisor.async(
      get_task_supervisor(),
      fn ->
        with_telemetry(task_opts, :async_task, fun)
      end,
      shutdown: task_opts.timeout
    )
  end

  @doc """
  Executes a function asynchronously without linking to caller.

  Use when you don't need to await the result.

  ## Example

      TaskRunner.async_nolink(fn ->
        fire_and_forget_operation()
      end)
  """
  @spec async_nolink((-> any()), keyword()) :: Task.t()
  def async_nolink(fun, opts \\ []) when is_function(fun, 0) do
    task_opts = build_task_opts(opts)

    Task.Supervisor.async_nolink(
      get_task_supervisor(),
      fn ->
        with_telemetry(task_opts, :async_task_nolink, fun)
      end,
      shutdown: task_opts.timeout
    )
  end

  # ============================================================================
  # Public API - Parallel Operations
  # ============================================================================

  @doc """
  Maps a function over a collection in parallel with supervision.

  Limits concurrency to avoid overwhelming resources.

  ## Options
  - `:max_concurrency` - Maximum concurrent tasks (default: 10)
  - `:timeout` - Timeout per task in ms (default: 30000)
  - `:ordered` - Preserve input order in results (default: true)

  ## Example

      bundles = [bundle1, bundle2, bundle3]

      results = TaskRunner.parallel_map(bundles, fn bundle ->
        submit_bundle(bundle)
      end, max_concurrency: 5)
  """
  @spec parallel_map(Enumerable.t(), (any() -> any()), keyword()) :: [any()]
  def parallel_map(enumerable, fun, opts \\ []) when is_function(fun, 1) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    ordered = Keyword.get(opts, :ordered, true)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    enumerable
    |> Task.Supervisor.async_stream(
      get_task_supervisor(),
      fun,
      max_concurrency: max_concurrency,
      timeout: timeout,
      ordered: ordered,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:task_exit, reason}}
    end)
  end

  @doc """
  Submits multiple bundles in parallel.

  Returns a list of results in the same order as input bundles.

  ## Example

      results = TaskRunner.parallel_submit(bundles,
        max_concurrency: 5,
        retry_strategy: RetryStrategy.linear()
      )
  """
  @spec parallel_submit([Bundle.t()], keyword()) :: [Bundle.t()]
  def parallel_submit(bundles, opts \\ []) do
    parallel_map(
      bundles,
      fn bundle ->
        submit_with_retry(bundle, opts)
      end,
      opts
    )
  end

  # ============================================================================
  # Public API - Rate Limiting
  # ============================================================================

  @doc """
  Executes a function with rate limiting.

  Ensures at most `max_per_second` executions per second.

  ## Example

      TaskRunner.with_rate_limit(10, fn ->
        api_call()
      end)
  """
  @spec with_rate_limit(non_neg_integer(), (-> any())) :: any()
  def with_rate_limit(max_per_second, fun) when is_function(fun, 0) do
    min_interval = div(1000, max_per_second)

    case get_last_execution_time() do
      nil ->
        set_last_execution_time()
        fun.()

      last_time ->
        elapsed = System.monotonic_time(:millisecond) - last_time

        if elapsed < min_interval do
          Process.sleep(min_interval - elapsed)
        end

        set_last_execution_time()
        fun.()
    end
  end

  # ============================================================================
  # Public API - Functional Composition
  # ============================================================================

  @doc """
  Creates a supervised pipeline of operations.

  Each operation runs in a supervised task with automatic error handling.

  ## Example

      result = TaskRunner.pipeline(bundle, [
        {:validate, &validate_bundle/1},
        {:simulate, &simulate_bundle/1},
        {:submit, &submit_bundle/1}
      ])
  """
  @spec pipeline(any(), [{atom(), (any() -> any())}], keyword()) :: task_result()
  def pipeline(initial_value, operations, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.Supervisor.async(
        get_task_supervisor(),
        fn ->
          Enum.reduce_while(operations, {:ok, initial_value}, fn {name, fun}, {:ok, value} ->
            case with_telemetry(%{telemetry: true}, name, fn -> fun.(value) end) do
              {:ok, result} -> {:cont, {:ok, result}}
              error -> {:halt, error}
            end
          end)
        end,
        shutdown: timeout
      )

    Task.await(task, timeout)
  end

  @doc """
  Runs tasks with automatic retry on failure.

  Combines task supervision with retry logic.

  ## Example

      TaskRunner.with_retry(fn ->
        unstable_operation()
      end, max_attempts: 3, backoff: :exponential)
  """
  @spec with_retry((-> any()), keyword()) :: task_result()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    backoff = Keyword.get(opts, :backoff, :exponential)

    task =
      Task.Supervisor.async(
        get_task_supervisor(),
        fn ->
          retry_loop(fun, max_attempts, backoff, 1)
        end
      )

    Task.await(task, Keyword.get(opts, :timeout, @default_timeout))
  end

  # ============================================================================
  # Public API - Resource Management
  # ============================================================================

  @doc """
  Executes a function with resource cleanup guarantee.

  Ensures cleanup runs even if the task fails or times out.

  ## Example

      TaskRunner.with_cleanup(
        fn -> acquire_resource() end,
        fn resource -> use_resource(resource) end,
        fn resource -> release_resource(resource) end
      )
  """
  @spec with_cleanup((-> any()), (any() -> any()), (any() -> any())) :: task_result()
  def with_cleanup(setup_fun, work_fun, cleanup_fun) do
    Task.Supervisor.async(
      get_task_supervisor(),
      fn ->
        resource = setup_fun.()

        try do
          work_fun.(resource)
        after
          cleanup_fun.(resource)
        end
      end
    )
    |> Task.await()
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_task_supervisor do
    case Registry.lookup(Ethers.MEV.Registry, :task_supervisor) do
      [{pid, _}] -> pid
      [] -> {:via, Registry, {Ethers.MEV.Registry, :task_supervisor}}
    end
  end

  defp build_task_opts(opts) do
    %{
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      telemetry: Keyword.get(opts, :telemetry, true)
    }
  end

  defp with_telemetry(%{telemetry: false}, _event, fun), do: fun.()

  defp with_telemetry(%{telemetry: true}, event, fun) do
    Telemetry.with_timing([:task_runner, event], fun)
  end

  defp submit_with_retry(bundle, opts) do
    strategy = Keyword.get(opts, :retry_strategy, RetryStrategy.exponential())

    RetryPipeline.submit_with_retry(bundle, %{
      strategy: strategy,
      provider: Keyword.fetch!(opts, :provider),
      provider_opts: Keyword.get(opts, :provider_opts, []),
      max_attempts: Keyword.get(opts, :max_attempts, 5)
    })
  end

  defp retry_loop(_fun, 0, _backoff, _attempt) do
    {:error, :max_attempts_exceeded}
  end

  defp retry_loop(fun, remaining, backoff, attempt) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, _} = error ->
        if remaining > 1 do
          delay = calculate_backoff(backoff, attempt)
          Process.sleep(delay)
          retry_loop(fun, remaining - 1, backoff, attempt + 1)
        else
          error
        end
    end
  end

  defp calculate_backoff(:exponential, attempt) do
    min(1000 * :math.pow(2, attempt - 1), 30_000) |> round()
  end

  defp calculate_backoff(:linear, attempt) do
    1000 * attempt
  end

  defp calculate_backoff(:none, _), do: 0

  # Simple rate limiting using process dictionary
  # In production, consider using ETS or a dedicated rate limiter
  defp get_last_execution_time do
    Process.get(:last_execution_time)
  end

  defp set_last_execution_time do
    Process.put(:last_execution_time, System.monotonic_time(:millisecond))
  end
end
