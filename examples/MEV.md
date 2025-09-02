# MEV (Maximum Extractable Value) Module

## Table of Contents
- [Overview](#overview)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [API Reference](#api-reference)
- [Examples](#examples)
- [Advanced Features](#advanced-features)

## Overview

The Ethers MEV module provides comprehensive support for Maximum Extractable Value operations on Ethereum. It includes bundle creation, submission to MEV relays, monitoring, and advanced features like retry strategies and circuit breakers.

### Key Features
- Bundle creation and validation
- Multiple MEV relay support (Flashbots, Eden, Bloxroute)
- Automatic retry with configurable strategies
- Circuit breaker for fault tolerance
- Bundle monitoring and inclusion tracking
- Pipeline-style functional API

## Installation

```elixir
def deps do
  [
    {:ethers, "~> 0.6"}
  ]
end
```

## Quick Start

### Basic Bundle Creation and Submission

```elixir
alias Ethers.MEV

# Create a bundle from signed transactions
{:ok, bundle} = MEV.create_bundle([tx1, tx2], block_number: 12345)

# Submit to MEV relay
{:ok, bundle_hash} = MEV.send_bundle(bundle,
  provider: Ethers.MEV.Providers.Flashbots,
  signer: signer
)
```

### Pipeline Style

```elixir
[tx1, tx2, tx3]
|> MEV.pipe_bundle(block_number: 12345)
|> MEV.with_timing(min: 1000, max: 2000)
|> MEV.pipe_simulate()
|> MEV.pipe_submit_if_profitable(min_profit: 1_000_000)
```

## Configuration

### Application Configuration

```elixir
# config/config.exs
config :ethers,
  default_mev_provider: Ethers.MEV.Providers.Flashbots,
  mev_network: :mainnet

config :ethereumex,
  url: System.get_env("ETH_RPC_URL", "http://localhost:8545")
```

### Runtime Options

All MEV functions accept runtime options that override defaults:

```elixir
opts = [
  provider: Ethers.MEV.Providers.Flashbots,
  network: :sepolia,
  signer: {Ethers.Signer.Local, private_key: key},
  retry_strategy: Ethers.MEV.RetryStrategy.exponential(),
  max_attempts: 5
]
```

## API Reference

### Core Functions

#### `create_bundle/2`
Creates a new bundle from transactions.

```elixir
@spec create_bundle([Transaction.t() | String.t()], keyword()) :: 
        {:ok, Bundle.t()} | {:error, term()}

# Options:
# - block_number: Target block (required)
# - min_timestamp: Minimum Unix timestamp
# - max_timestamp: Maximum Unix timestamp
# - reverting_tx_hashes: Transactions allowed to revert
# - replacement_uuid: UUID for bundle replacement
```

#### `send_bundle/2`
Submits a bundle to the MEV relay.

```elixir
@spec send_bundle(Bundle.t(), keyword()) :: 
        {:ok, String.t()} | {:error, term()}

# Returns bundle hash on success
```

#### `simulate_bundle/2`
Simulates bundle execution without submission.

```elixir
@spec simulate_bundle(Bundle.t(), keyword()) :: 
        {:ok, map()} | {:error, term()}

# Returns simulation results including:
# - coinbase_diff: Profit in wei
# - gas_used: Total gas consumed
# - results: Per-transaction results
```

#### `monitor_bundle/3`
Monitors bundle inclusion status.

```elixir
@spec monitor_bundle(String.t(), non_neg_integer(), keyword()) :: 
        {:ok, pid()} | {:error, term()}

# Returns monitor process that tracks bundle status
```

### Pipeline Functions

#### `pipe_bundle/2`
Creates a bundle in pipeline style.

```elixir
@spec pipe_bundle([Transaction.t()], keyword()) :: Bundle.t()
```

#### `pipe_simulate/2`
Simulates and attaches results to bundle.

```elixir
@spec pipe_simulate(Bundle.t(), keyword()) :: Bundle.t()
```

#### `pipe_submit_if_profitable/2`
Conditionally submits based on profitability.

```elixir
@spec pipe_submit_if_profitable(Bundle.t(), keyword()) :: 
        {:ok, String.t()} | {:skip, map()}
```

### Bundle Struct

```elixir
%Ethers.MEV.Bundle{
  transactions: [binary()],          # Signed transactions
  block_number: non_neg_integer(),   # Target block
  min_timestamp: integer() | nil,    # Min timestamp
  max_timestamp: integer() | nil,    # Max timestamp
  reverting_tx_hashes: [String.t()], # Reverts allowed
  replacement_uuid: String.t() | nil # For replacements
}
```

## Examples

See the [examples directory](../examples/) for complete working examples:

- [Basic Bundle](../examples/mev_bundle_example.exs) - Simple bundle creation and submission
- [Arbitrage Bot](../examples/mev_arbitrage.exs) - DEX arbitrage implementation
- [Sandwich Protection](../examples/mev_sandwich_protection.exs) - Protecting against sandwich attacks
- [Performance Benchmark](../examples/mev_bench.exs) - Bundle submission benchmarking

## Advanced Features

### Retry Strategies

Configure automatic retry behavior:

```elixir
# Exponential backoff
strategy = Ethers.MEV.RetryStrategy.exponential(
  initial_delay: 1000,
  max_delay: 30_000,
  factor: 2
)

# Linear backoff
strategy = Ethers.MEV.RetryStrategy.linear(
  delay: 2000
)

# Use with submission
MEV.send_bundle(bundle, retry_strategy: strategy, max_attempts: 5)
```

### Circuit Breaker

Automatic fault tolerance:

```elixir
# Circuit breaker configuration
config = %{
  failure_threshold: 5,    # Failures before opening
  timeout: 60_000,         # Reset timeout in ms
  half_open_requests: 3    # Test requests in half-open
}

# Automatically managed by supervisor
```

### Bundle Monitoring

Track bundle inclusion:

```elixir
{:ok, monitor} = MEV.monitor_bundle(bundle_hash, target_block,
  check_interval: 2000,
  max_wait: 5
)

case Ethers.MEV.BundleMonitor.wait_for_inclusion(monitor) do
  {:ok, :included} -> "Success!"
  {:ok, :not_included} -> "Not included"
  {:error, :timeout} -> "Timed out"
end
```

### Conflict Detection

Check for conflicts before submission:

```elixir
case MEV.check_and_send(bundle, check_mempool: true) do
  {:ok, hash} -> "Submitted: #{hash}"
  {:error, {:conflicts, conflicts}} -> "Conflicts found"
end
```

### Task Runner

Parallel bundle operations:

```elixir
bundles = [bundle1, bundle2, bundle3]

results = Ethers.MEV.TaskRunner.parallel_submit(bundles,
  max_concurrency: 5,
  retry_strategy: strategy
)
```

## Provider-Specific Configuration

### Flashbots

```elixir
opts = [
  provider: Ethers.MEV.Providers.Flashbots,
  network: :mainnet,  # or :sepolia, :holesky
  signer: {Ethers.Signer.Flashbots, private_key: key}
]
```

### Eden Network (Coming Soon)

```elixir
opts = [
  provider: Ethers.MEV.Providers.Eden,
  api_key: "your-eden-api-key"
]
```

### Bloxroute (Coming Soon)

```elixir
opts = [
  provider: Ethers.MEV.Providers.Bloxroute,
  auth_token: "your-bloxroute-token"
]
```

## Error Handling

All functions return tagged tuples for explicit error handling:

```elixir
case MEV.send_bundle(bundle, opts) do
  {:ok, bundle_hash} ->
    Logger.info("Bundle submitted: #{bundle_hash}")
    
  {:error, :invalid_bundle} ->
    Logger.error("Bundle validation failed")
    
  {:error, {:provider_error, reason}} ->
    Logger.error("Provider error: #{inspect(reason)}")
    
  {:error, reason} ->
    Logger.error("Unexpected error: #{inspect(reason)}")
end
```

## Testing

The module includes comprehensive test helpers:

```elixir
alias Ethers.MEV.TestHelpers

# Create test bundle
bundle = TestHelpers.create_test_bundle(
  transaction_count: 3,
  block_number: 100
)

# Start Anvil for testing
{:ok, _} = TestHelpers.start_anvil(port: 8545)

# Verify bundle inclusion
{:ok, included} = TestHelpers.verify_bundle_inclusion(
  bundle,
  block_number
)
```

## Performance Considerations

- Bundle size: Keep under 50 transactions
- Gas prices: Use competitive pricing for inclusion
- Timing: Submit 2-3 blocks before target
- Monitoring: Use async monitoring for multiple bundles
- Retry: Configure appropriate retry strategies

## Security

- Always use secure key management
- Validate transaction inputs
- Monitor for unusual behavior
- Use circuit breakers in production
- Implement rate limiting
- Audit bundle contents before submission

## Support

For issues, questions, or contributions:
- [GitHub Issues](https://github.com/your-repo/issues)
- [Documentation](https://hexdocs.pm/ethers)