# Operations

## Chainlink Automation

- **Upkeep contract**: `UpDownAutoCycler` (`checkUpkeep` / `performUpkeep`).
- Register the deployed cycler at [Chainlink Automation](https://automation.chain.link/) for Arbitrum.
- Fund the upkeep with **LINK** (or native billing per Chainlink docs).

### Cost monitoring

- Review **gas per performUpkeep** on Arbiscan (varies with number of resolutions + creations).
- Budget roughly **$150–250/mo** as a planning figure; tune from mainnet data.
- Alert on: failed upkeeps, `ResolutionFailed` / `MarketCreationFailed` events, unusually high `activeMarketCount`.

## Contract ops (ETH pair)

See [`contracts/docs/ONCHAIN_OPERATIONS.md`](../contracts/docs/ONCHAIN_OPERATIONS.md) for `configureFeed` / `addPair` cast examples.

## Pruning

`performUpkeep` calls `_pruneResolved()` to drop finalized pools from the in-contract active array. Owner may also call `pruneResolved()` manually if needed.

## Health checks

Use `GET /health` (no rate limit) for uptime probes: `status`, `relayer`, `uptime`.

## Production addresses

| Item | Dev (example) | Prod (Arbitrum) |
|------|----------------|-----------------|
| USDT | `0xCa4f77A38d8552Dd1D5E44e890173921B67725F4` | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| Factory | `0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc` | `0xA8640B62D755e42C9ed6A86d0fc65CE09e31F264` |

Set via `backend` and deployment env (see `.env.example` files).
