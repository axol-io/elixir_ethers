defmodule Ethers.MEV.Telemetry do
  @moduledoc """
  Telemetry instrumentation for MEV operations.

  This module provides telemetry event emission for bundle lifecycle,
  provider operations, and retry behavior. All functions are designed
  to be composed functionally with your MEV pipelines.

  ## Events

  The following events are emitted:

  - `[:ethers, :mev, :bundle, :created]` - Bundle creation
  - `[:ethers, :mev, :bundle, :submitted]` - Bundle submission
  - `[:ethers, :mev, :bundle, :included]` - Bundle inclusion
  - `[:ethers, :mev, :bundle, :failed]` - Bundle failure
  - `[:ethers, :mev, :bundle, :retry]` - Bundle retry
  - `[:ethers, :mev, :simulation, :start]` - Simulation start
  - `[:ethers, :mev, :simulation, :stop]` - Simulation complete
  - `[:ethers, :mev, :provider, :request]` - Provider request

  ## Usage

      # Wrap operations with telemetry
      bundle
      |> Telemetry.with_event(:bundle_created)
      |> simulate()
      |> Telemetry.with_timing(:simulation)
      |> submit()
      |> Telemetry.with_event(:bundle_submitted)

  ## Attaching Handlers

      :telemetry.attach(
        "mev-logger",
        [:ethers, :mev, :bundle, :submitted],
        &handle_event/4,
        nil
      )
  """

  alias Ethers.MEV.{Bundle, BundleState}

  @type event_name :: atom() | [atom()]
  @type measurements :: map()
  @type metadata :: map()

  # ============================================================================
  # Event Emission (Side Effects in Controlled Manner)
  # ============================================================================

  @doc """
  Emits a telemetry event and returns the input value unchanged.

  This allows telemetry to be added to pipelines without affecting data flow.

  ## Example

      bundle
      |> create_bundle()
      |> Telemetry.emit(:bundle_created)
      |> submit_bundle()
  """
  @spec emit(any(), event_name(), measurements(), metadata()) :: any()
  def emit(value, event_name, measurements \\ %{}, metadata \\ %{}) do
    execute(normalize_event_name(event_name), measurements, metadata)
    value
  end

  @doc """
  Wraps a function with telemetry timing.

  Measures execution time and emits start/stop events.

  ## Example

      result = Telemetry.with_timing(:simulation, fn ->
        simulate_bundle(bundle)
      end)
  """
  @spec with_timing(event_name(), (-> any())) :: any()
  def with_timing(event_name, fun) when is_function(fun, 0) do
    event = normalize_event_name(event_name)
    start_time = System.monotonic_time()

    execute(event ++ [:start], %{system_time: System.system_time()}, %{})

    try do
      result = fun.()

      duration = System.monotonic_time() - start_time

      execute(
        event ++ [:stop],
        %{duration: duration, system_time: System.system_time()},
        %{status: :ok}
      )

      result
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        execute(
          event ++ [:exception],
          %{duration: duration, system_time: System.system_time()},
          %{kind: :error, reason: error, stacktrace: __STACKTRACE__}
        )

        reraise error, __STACKTRACE__
    end
  end

  @doc """
  Adds telemetry to a pipeline step.

  Returns a function that emits telemetry and applies the given function.

  ## Example

      bundle
      |> Telemetry.instrument(:validate, &validate_bundle/1)
      |> Telemetry.instrument(:submit, &submit_bundle/1)
  """
  @spec instrument(any(), event_name(), (any() -> any())) :: any()
  def instrument(value, event_name, fun) when is_function(fun, 1) do
    with_timing(event_name, fn -> fun.(value) end)
  end

  # ============================================================================
  # Bundle Lifecycle Events
  # ============================================================================

  @doc """
  Emits bundle creation event.
  """
  @spec bundle_created(Bundle.t()) :: Bundle.t()
  def bundle_created(%Bundle{} = bundle) do
    measurements = %{
      transaction_count: length(bundle.transactions),
      target_block: bundle.block_number
    }

    metadata = %{
      has_timing_constraints: bundle.min_timestamp != nil or bundle.max_timestamp != nil,
      has_reverting_hashes: bundle.reverting_tx_hashes != nil,
      has_replacement_uuid: bundle.replacement_uuid != nil
    }

    emit(bundle, [:bundle, :created], measurements, metadata)
  end

  @doc """
  Emits bundle submission event.
  """
  @spec bundle_submitted(Bundle.t(), String.t()) :: Bundle.t()
  def bundle_submitted(%Bundle{} = bundle, bundle_hash) do
    measurements = %{
      target_block: bundle.block_number
    }

    metadata = %{
      bundle_hash: bundle_hash,
      transaction_count: length(bundle.transactions)
    }

    emit(bundle, [:bundle, :submitted], measurements, metadata)
  end

  @doc """
  Emits bundle state transition event.
  """
  @spec state_transition(BundleState.t()) :: BundleState.t()
  def state_transition(%BundleState{} = state) do
    case BundleState.latest_transition(state) do
      nil ->
        state

      transition ->
        measurements = %{
          retry_count: state.retry_count,
          elapsed_time: BundleState.time_since_submission(state) || 0
        }

        metadata = %{
          from_status: transition.from,
          to_status: transition.to,
          bundle_hash: state.bundle_hash,
          target_block: state.target_block,
          transition_metadata: transition.metadata
        }

        event_name = status_to_event(transition.to)
        emit(state, [:bundle, event_name], measurements, metadata)
    end
  end

  # ============================================================================
  # Provider Events
  # ============================================================================

  @doc """
  Emits provider request event.
  """
  @spec provider_request(map(), atom(), atom()) :: map()
  def provider_request(request, provider, method) do
    measurements = %{
      request_size: estimate_size(request)
    }

    metadata = %{
      provider: provider,
      method: method
    }

    emit(request, [:provider, :request], measurements, metadata)
  end

  @doc """
  Emits provider response event.
  """
  @spec provider_response(map(), atom(), atom(), non_neg_integer()) :: map()
  def provider_response(response, provider, method, duration) do
    measurements = %{
      duration: duration,
      response_size: estimate_size(response)
    }

    metadata = %{
      provider: provider,
      method: method,
      success: Map.has_key?(response, :error) == false
    }

    emit(response, [:provider, :response], measurements, metadata)
  end

  # ============================================================================
  # Retry Events
  # ============================================================================

  @doc """
  Emits retry attempt event.
  """
  @spec retry_attempt(BundleState.t(), non_neg_integer()) :: BundleState.t()
  def retry_attempt(%BundleState{} = state, delay) do
    measurements = %{
      attempt: state.retry_count,
      delay: delay,
      elapsed_time: BundleState.time_since_submission(state) || 0
    }

    metadata = %{
      bundle_hash: state.bundle_hash,
      target_block: state.target_block,
      last_error: inspect(state.last_error),
      max_retries: state.max_retries
    }

    emit(state, [:bundle, :retry], measurements, metadata)
  end

  # ============================================================================
  # Functional Telemetry Pipelines
  # ============================================================================

  @doc """
  Creates a telemetry-instrumented pipeline.

  Each step in the pipeline emits appropriate telemetry events.

  ## Example

      bundle
      |> Telemetry.pipeline([
        {:create, &create_bundle/1},
        {:validate, &validate_bundle/1},
        {:simulate, &simulate_bundle/1},
        {:submit, &submit_bundle/1}
      ])
  """
  @spec pipeline(any(), [{atom(), (any() -> any())}]) :: any()
  def pipeline(initial_value, steps) do
    Enum.reduce(steps, initial_value, fn {name, fun}, acc ->
      instrument(acc, name, fun)
    end)
  end

  @doc """
  Wraps a value with success/failure telemetry based on pattern matching.

  ## Example

      bundle
      |> submit()
      |> Telemetry.with_result(:submission,
        ok: fn {:ok, hash} -> emit_success(hash) end,
        error: fn {:error, reason} -> emit_failure(reason) end
      )
  """
  @spec with_result(any(), event_name(), keyword()) :: any()
  def with_result(value, event_name, patterns) do
    event = normalize_event_name(event_name)

    case value do
      {:ok, result} ->
        if fun = patterns[:ok] do
          fun.(result)
        end

        execute(
          event ++ [:success],
          %{system_time: System.system_time()},
          %{result: result}
        )

        value

      {:error, reason} ->
        if fun = patterns[:error] do
          fun.(reason)
        end

        execute(
          event ++ [:failure],
          %{system_time: System.system_time()},
          %{reason: reason}
        )

        value

      _ ->
        value
    end
  end

  # ============================================================================
  # Telemetry Span Support
  # ============================================================================

  @doc """
  Starts a telemetry span for tracking complex operations.

  Returns a span context that can be used to emit related events.

  ## Example

      span = Telemetry.start_span(:bundle_lifecycle, %{bundle_id: id})
      
      # ... operations ...
      
      Telemetry.end_span(span, %{status: :success})
  """
  @spec start_span(event_name(), metadata()) :: map()
  def start_span(event_name, metadata \\ %{}) do
    span_id = generate_span_id()
    start_time = System.monotonic_time()

    span = %{
      id: span_id,
      event: normalize_event_name(event_name),
      start_time: start_time,
      metadata: metadata
    }

    execute(
      span.event ++ [:start],
      %{system_time: System.system_time()},
      Map.put(metadata, :span_id, span_id)
    )

    span
  end

  @doc """
  Ends a telemetry span.
  """
  @spec end_span(map(), metadata()) :: :ok
  def end_span(span, additional_metadata \\ %{}) do
    duration = System.monotonic_time() - span.start_time

    metadata =
      span.metadata
      |> Map.merge(additional_metadata)
      |> Map.put(:span_id, span.id)

    execute(
      span.event ++ [:stop],
      %{duration: duration, system_time: System.system_time()},
      metadata
    )

    :ok
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp execute(event, measurements, metadata) do
    :telemetry.execute(
      [:ethers, :mev] ++ List.wrap(event),
      measurements,
      metadata
    )
  end

  defp normalize_event_name(name) when is_atom(name), do: [name]
  defp normalize_event_name(name) when is_list(name), do: name

  defp status_to_event(:submitted), do: :submitted
  defp status_to_event(:included), do: :included
  defp status_to_event(:failed), do: :failed
  defp status_to_event(:expired), do: :expired
  defp status_to_event(:retry), do: :retry
  defp status_to_event(_), do: :transition

  defp estimate_size(data) when is_map(data) do
    data
    |> Jason.encode!()
    |> byte_size()
  rescue
    _ -> 0
  end

  defp estimate_size(data) when is_binary(data), do: byte_size(data)
  defp estimate_size(_), do: 0

  defp generate_span_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end
end
