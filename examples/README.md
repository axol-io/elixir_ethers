# Ethers MEV Examples

This directory contains practical examples demonstrating MEV functionality using the Ethers library.

## Running Examples

All examples can be run directly with Elixir:

```bash
# Basic example
elixir examples/mev_bundle_example.exs

# With Anvil running (required for most examples)
anvil --port 8545
elixir examples/[example_name].exs
```

## Examples by Complexity

### 🟢 Basic

#### [mev_bundle_example.exs](./mev_bundle_example.exs)
**Purpose**: Introduction to bundle creation and submission  
**Concepts**: Bundle creation, transaction signing, pipeline operations  
**Requirements**: Anvil (optional)

```elixir
# Key operations demonstrated:
- Creating signed transactions
- Building bundles with constraints
- Pipeline-style bundle composition
- Bundle monitoring basics
```

### 🟡 Intermediate

#### [mev_arbitrage.exs](./mev_arbitrage.exs)
**Purpose**: DEX arbitrage bot implementation  
**Concepts**: Price discovery, optimal routing, profit calculation  
**Requirements**: Anvil with deployed DEX contracts

```elixir
# Key operations demonstrated:
- Cross-DEX price monitoring
- Arbitrage opportunity detection
- Optimal trade sizing
- Bundle submission with profit threshold
```

#### [mev_sandwich_protection.exs](./mev_sandwich_protection.exs)
**Purpose**: Protect large trades from sandwich attacks  
**Concepts**: Private transactions, commit-reveal patterns  
**Requirements**: Anvil, Flashbots relay access

```elixir
# Key operations demonstrated:
- Private transaction submission
- Sandwich attack detection
- Protection strategies
- Bundle timing optimization
```

### 🔴 Advanced

#### [mev_bench.exs](./mev_bench.exs)
**Purpose**: Performance benchmarking and optimization  
**Concepts**: Parallel submission, latency measurement  
**Requirements**: Anvil, multiple accounts

```elixir
# Key operations demonstrated:
- Concurrent bundle creation
- Performance metrics collection
- Retry strategy comparison
- Circuit breaker testing
```

## Common Patterns

### Bundle Creation Pattern
```elixir
# Standard approach used across examples
def create_bundle(transactions, block_number) do
  transactions
  |> MEV.bundle(block_number: block_number)
  |> MEV.with_timing(max: :os.system_time(:second) + 60)
  |> MEV.with_reverting_hashes(allowed_reverts)
end
```

### Simulation Before Submission
```elixir
# Check profitability before sending
bundle
|> MEV.pipe_simulate(opts)
|> MEV.pipe_submit_if_profitable(min_profit: threshold)
```

### Error Handling
```elixir
# Consistent error handling pattern
case MEV.send_bundle(bundle, opts) do
  {:ok, hash} -> handle_success(hash)
  {:error, reason} -> handle_error(reason)
end
```

## Configuration

All examples use similar configuration patterns:

```elixir
# Test accounts (Anvil defaults)
@accounts [
  %{
    address: "0xf39F...",
    private_key: "0xac09..."
  }
]

# Provider configuration
@provider_opts [
  provider: Ethers.MEV.Providers.Flashbots,
  network: :sepolia,
  rpc_url: "http://localhost:8545"
]
```

## Prerequisites

### Required Tools
- Elixir 1.14+
- Anvil (from Foundry)
- Git

### Setup
```bash
# Install dependencies
mix deps.get

# Start Anvil in a separate terminal
anvil --port 8545 --chain-id 1

# Run any example
elixir examples/[example_name].exs
```

## Extending Examples

To create your own MEV example:

1. Copy the basic template:
```bash
cp examples/mev_bundle_example.exs examples/my_example.exs
```

2. Modify for your use case:
```elixir
defmodule MyMEVStrategy do
  alias Ethers.MEV
  
  def run do
    # Your MEV logic here
  end
end
```

3. Test with Anvil:
```bash
elixir examples/my_example.exs
```

## Testing Strategies

### Local Testing (Anvil)
- Fast iteration
- No real costs
- Full control over blockchain state

### Testnet (Sepolia/Holesky)
- Real network conditions
- Actual MEV relay interaction
- No mainnet costs

### Mainnet
- Real profits/losses
- Production latency
- Actual competition

## Troubleshooting

### Common Issues

**"No provider configured"**
```elixir
# Ensure provider is specified
opts = [provider: Ethers.MEV.Providers.Flashbots]
```

**"Invalid signature"**
```elixir
# Check signer configuration
signer = {Ethers.Signer.Local, private_key: key}
```

**"Bundle not included"**
- Increase gas price
- Check target block
- Verify transaction validity
- Monitor mempool competition

## Additional Resources

- [MEV Documentation](../docs/MEV.md)
- [Flashbots Documentation](https://docs.flashbots.net)
- [Ethers Hex Docs](https://hexdocs.pm/ethers)

## Contributing

To contribute an example:
1. Follow the existing pattern
2. Include clear documentation
3. Test with Anvil
4. Submit a PR with description

## License

These examples are part of the Ethers library and follow the same license.