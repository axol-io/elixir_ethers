defmodule Ethers.MEV.BundleState do
  @moduledoc """
  Functional state management for MEV bundles.

  This module provides pure functions for managing bundle state transitions,
  implementing a functional state machine pattern without GenServer.

  ## State Transitions

  The bundle lifecycle follows these transitions:

      pending -> submitted -> included (success)
                          `-> failed -> retry -> submitted
                          `-> expired (timeout)

  ## Example

      state = BundleState.new(bundle, opts)
      |> BundleState.transition(:submitted, %{hash: "0x..."})
      |> BundleState.increment_retry()
      
      case BundleState.should_retry?(state) do
        true -> submit_with_retry(state)
        false -> {:error, :max_retries_exceeded}
      end
  """

  alias Ethers.MEV.Bundle

  @type status :: :pending | :submitted | :included | :failed | :expired | :retry
  @type metadata :: map()

  @type t :: %__MODULE__{
          bundle: Bundle.t(),
          status: status(),
          retry_count: non_neg_integer(),
          max_retries: non_neg_integer(),
          submitted_at: DateTime.t() | nil,
          included_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          last_error: term() | nil,
          bundle_hash: String.t() | nil,
          target_block: non_neg_integer(),
          metadata: metadata(),
          history: list(transition())
        }

  @type transition :: %{
          from: status(),
          to: status(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:bundle, :target_block]
  defstruct [
    :bundle,
    :bundle_hash,
    :target_block,
    :submitted_at,
    :included_at,
    :failed_at,
    :last_error,
    status: :pending,
    retry_count: 0,
    max_retries: 5,
    metadata: %{},
    history: []
  ]

  # ============================================================================
  # State Creation and Initialization
  # ============================================================================

  @doc """
  Creates a new bundle state.

  ## Options
  - `:max_retries` - Maximum retry attempts (default: 5)
  - `:target_block` - Target block for inclusion (required if not in bundle)
  - `:metadata` - Additional metadata to store
  """
  @spec new(Bundle.t(), keyword()) :: t()
  def new(%Bundle{} = bundle, opts \\ []) do
    %__MODULE__{
      bundle: bundle,
      target_block: opts[:target_block] || bundle.block_number,
      max_retries: Keyword.get(opts, :max_retries, 5),
      metadata: Keyword.get(opts, :metadata, %{}),
      history: []
    }
  end

  # ============================================================================
  # State Transitions (Pure Functions)
  # ============================================================================

  @doc """
  Transitions the state to a new status.

  Records the transition in history and updates relevant timestamps.
  Returns the updated state.

  ## Examples

      state
      |> BundleState.transition(:submitted, %{hash: "0x123"})
      |> BundleState.transition(:included, %{block: 12345})
  """
  @spec transition(t(), status(), metadata()) :: t()
  def transition(%__MODULE__{status: from_status} = state, to_status, metadata \\ %{}) do
    timestamp = DateTime.utc_now()

    transition_record = %{
      from: from_status,
      to: to_status,
      timestamp: timestamp,
      metadata: metadata
    }

    state
    |> Map.put(:status, to_status)
    |> Map.put(:history, [transition_record | state.history])
    |> update_timestamps(to_status, timestamp)
    |> update_metadata(to_status, metadata)
  end

  @doc """
  Marks the bundle as submitted.
  """
  @spec mark_submitted(t(), String.t()) :: t()
  def mark_submitted(state, bundle_hash) do
    state
    |> Map.put(:bundle_hash, bundle_hash)
    |> transition(:submitted, %{hash: bundle_hash})
  end

  @doc """
  Marks the bundle as included.
  """
  @spec mark_included(t(), non_neg_integer()) :: t()
  def mark_included(state, block_number) do
    transition(state, :included, %{block: block_number})
  end

  @doc """
  Marks the bundle as failed with an error.
  """
  @spec mark_failed(t(), term()) :: t()
  def mark_failed(state, error) do
    state
    |> Map.put(:last_error, error)
    |> transition(:failed, %{error: inspect(error)})
  end

  @doc """
  Marks the bundle as expired.
  """
  @spec mark_expired(t()) :: t()
  def mark_expired(state) do
    transition(state, :expired, %{
      target_block: state.target_block,
      retry_count: state.retry_count
    })
  end

  @doc """
  Prepares the state for retry.
  Increments retry count and transitions to retry status.
  """
  @spec prepare_retry(t()) :: {:ok, t()} | {:error, :max_retries_exceeded}
  def prepare_retry(%__MODULE__{} = state) do
    if should_retry?(state) do
      updated_state =
        state
        |> Map.update!(:retry_count, &(&1 + 1))
        |> transition(:retry, %{attempt: state.retry_count + 1})

      {:ok, updated_state}
    else
      {:error, :max_retries_exceeded}
    end
  end

  # ============================================================================
  # State Queries (Pure Functions)
  # ============================================================================

  @doc """
  Checks if the bundle should be retried.
  """
  @spec should_retry?(t()) :: boolean()
  def should_retry?(%__MODULE__{} = state) do
    state.retry_count < state.max_retries and
      state.status in [:failed, :retry] and
      not expired?(state)
  end

  @doc """
  Checks if the bundle has expired.

  A bundle is expired if the current block is past the target block
  plus a buffer (default: 25 blocks).
  """
  @spec expired?(t(), non_neg_integer() | nil) :: boolean()
  def expired?(%__MODULE__{} = state, current_block \\ nil) do
    case current_block do
      nil -> state.status == :expired
      block -> block > state.target_block + 25
    end
  end

  @doc """
  Checks if the bundle is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:included, :expired]
  end

  @doc """
  Checks if the bundle is pending submission.
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: status}) do
    status == :pending
  end

  @doc """
  Gets the time since submission in milliseconds.
  Returns nil if not submitted.
  """
  @spec time_since_submission(t()) :: non_neg_integer() | nil
  def time_since_submission(%__MODULE__{submitted_at: nil}), do: nil

  def time_since_submission(%__MODULE__{submitted_at: submitted_at}) do
    DateTime.diff(DateTime.utc_now(), submitted_at, :millisecond)
  end

  @doc """
  Gets statistics about the bundle state.
  """
  @spec get_stats(t()) :: map()
  def get_stats(%__MODULE__{} = state) do
    %{
      status: state.status,
      retry_count: state.retry_count,
      max_retries: state.max_retries,
      time_since_submission: time_since_submission(state),
      transition_count: length(state.history),
      is_terminal: terminal?(state),
      should_retry: should_retry?(state)
    }
  end

  # ============================================================================
  # State Transformations (Pure Functions)
  # ============================================================================

  @doc """
  Updates the bundle in the state.

  Useful for modifying bundle parameters before retry.
  """
  @spec update_bundle(t(), (Bundle.t() -> Bundle.t())) :: t()
  def update_bundle(%__MODULE__{bundle: bundle} = state, update_fn) do
    %{state | bundle: update_fn.(bundle)}
  end

  @doc """
  Updates the target block for the bundle.
  """
  @spec update_target_block(t(), non_neg_integer()) :: t()
  def update_target_block(%__MODULE__{} = state, new_target) do
    state
    |> Map.put(:target_block, new_target)
    |> update_bundle(fn bundle ->
      %{bundle | block_number: new_target}
    end)
  end

  @doc """
  Adds metadata to the state.
  """
  @spec add_metadata(t(), map()) :: t()
  def add_metadata(%__MODULE__{metadata: current} = state, new_metadata) do
    %{state | metadata: Map.merge(current, new_metadata)}
  end

  @doc """
  Gets the latest transition from history.
  """
  @spec latest_transition(t()) :: transition() | nil
  def latest_transition(%__MODULE__{history: []}), do: nil
  def latest_transition(%__MODULE__{history: [latest | _]}), do: latest

  @doc """
  Filters transition history by status.
  """
  @spec transitions_to(t(), status()) :: [transition()]
  def transitions_to(%__MODULE__{history: history}, status) do
    Enum.filter(history, fn transition -> transition.to == status end)
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp update_timestamps(state, :submitted, timestamp) do
    %{state | submitted_at: timestamp}
  end

  defp update_timestamps(state, :included, timestamp) do
    %{state | included_at: timestamp}
  end

  defp update_timestamps(state, :failed, timestamp) do
    %{state | failed_at: timestamp}
  end

  defp update_timestamps(state, _, _), do: state

  defp update_metadata(state, :submitted, %{hash: hash}) do
    %{state | bundle_hash: hash}
  end

  defp update_metadata(state, _, _), do: state
end
