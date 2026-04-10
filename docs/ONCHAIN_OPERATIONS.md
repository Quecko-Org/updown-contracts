# On-chain operations (ETH/USD and resolver)

## New deployments

[`script/Deploy.s.sol`](../script/Deploy.s.sol) deploys `ChainlinkResolver` with both **BTC/USD** and **ETH/USD** Chainlink feeds (Arbitrum mainnet addresses) and calls **`addPair(keccak256("ETH/USD"))`** on `UpDownAutoCycler` so automation creates pools for both pairs.

## Existing deployments (manual)

If the resolver was deployed with `ETH` feed unset (`address(0)`), owner must set it:

```bash
# Pair id = keccak256("ETH/USD") — use cast keccak
PAIR=$(cast keccak "ETH/USD")
cast send <RESOLVER> "configureFeed(bytes32,address)" "$PAIR" 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 \
  --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

Enable ETH on an existing cycler (owner):

```bash
PAIR=$(cast keccak "ETH/USD")
cast send <CYCLER> "addPair(bytes32)" "$PAIR" \
  --rpc-url $ARBITRUM_RPC_URL --account <OWNER>
```

## Authorization

`UpDownAutoCycler` must be **`setAuthorizedCaller(cycler, true)`** on `ChainlinkResolver` so `registerMarket` succeeds during `performUpkeep`. The deploy script does this; verify on upgraded deployments.

## Reference addresses (Arbitrum One)

| Item            | Address |
|-----------------|--------|
| Chainlink ETH/USD | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` |
| Chainlink BTC/USD | `0x6ce185860a4963106506C203335A2910413708e9` |
| Chainlink sequencer | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |
