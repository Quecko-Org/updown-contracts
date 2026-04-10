# UpDown Markets — Cowork Context

Read this entire file before doing anything. Every decision in here is locked. If you see code that contradicts it, that's a bug.

---

## What This Project Is

UpDown is a Polymarket-style UP/DOWN price prediction market built on RAIN Protocol on Arbitrum. Users predict if an asset goes UP or DOWN within a fixed window. Architecture: **off-chain order matching (centralized, like Polymarket), on-chain settlement.** Goal: ship before Hyperliquid's HIP-4 hits mainnet as the first decentralized up/down prediction market.

Built for bots — market maker bots (posting two-sided quotes, earning 0.8% maker fee) and taker bots (latency arb, signal-based trading). Pure order book, no LP pool, no AMM.

---

## Monorepo Structure

```
/contracts     — Phase 1: ChainlinkResolver + UpDownAutoCycler (23 tests passing)
/backend       — Phase 2+3: Matching engine, API, services (32 tests passing)
/frontend      — Phase 4: Next.js frontend
/sdk/typescript — Phase 5: TypeScript bot SDK
/sdk/python    — Phase 5: Python bot SDK
/docs          — API docs, bot guide, operations, e2e checklist
```

All 5 phases are complete.

---

## Locked Decisions — These Are Not Variables

### Order Book
- **Pure order book like Polymarket. No LP pool. No AMM backstop. No passive liquidity.**
- Market makers provide all liquidity by posting limit orders on both sides of the book.
- Matching is off-chain in the backend matching engine. NOT on-chain.
- We do NOT use RAIN's `placeBuyOrder`/`placeSellOrder` on-chain order book.
- We use `enterOption()` only — to enter aggregate positions backing off-chain matched trades.
- Cancel priority enforced by the matching engine: cancels process before taker orders in each batch.
- Price-time priority for matching.

### Fees
- **0.7% platform fee + 0.8% maker fee = 1.5% total**
- **Fees must be easily configurable** — set via env vars / factory params, not hardcoded
- Any 3.6%, 5%, or other fee percentage in the code is WRONG
- Creator fee: 0% — markets are auto-generated, no creator entity exists

### Timeframes
- **5 minutes, 15 minutes, 60 minutes**
- NOT 5/10/15. NOT 1 minute.
- UI labels: "5 min", "15 min", "1 hour"
- Contract durations: 300s, 900s, 3600s

### Dispute Windows
- **2x the prediction time**: 10 min (for 5-min), 30 min (for 15-min), 120 min (for 60-min)
- Disputes stay enabled — hard constraint
- Passed as `oracleEndTime` (duration, NOT absolute timestamp)

### Pairs
- **BTC/USD at MVP. ETH/USD added in Phase 5.**
- ETH/USD Chainlink feed: `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612`
- Pairs shown as tabs within each timeframe section, not separate rows

### Options
- 1-indexed: **UP = option 1, DOWN = option 2**
- Resolution sequence: `closePool()` first, then `chooseWinner()`
- Tie (price == strike within 0.001%): DOWN wins

### Settlement (Custodial Model)
- Users deposit USDT to relayer wallet
- `DepositService` monitors Transfer events, credits MongoDB Balance records
- Engine checks Balance.available >= order.amount before accepting orders
- After matching, `SettlementService` calls `enterOption()` from relayer for aggregate positions
- At resolution, `ClaimService` calls `pool.claim()` from relayer, distributes to winners via MongoDB
- Explicitly custodial — all on-chain positions belong to relayer wallet
- Individual user positions tracked in MongoDB only

### Market Creation
- `initialLiquidity` minimum $10 USDT (10_000_000 wei, 6 decimals) — factory enforces this
- `liquidityPercentages`: [5000, 5000] (basis points summing to 10000)
- Markets created with `isPublic: false`, `poolResolver` = ChainlinkResolver address
- `oracleEndTime` is a DURATION not an absolute timestamp

### Data Sources
- MongoDB is the source of truth for markets, trades, balances, positions
- RAIN subgraph is NOT used — on-chain only reflects relayer aggregates
- Price history proxied from speed-market API at `rain-speed-markets-dev-api.quecko.org`

### Contracts (Arbitrum)
```
RAIN TradingFacet:       0xB292c8E18c1bD5861A2734412F0078C18aCBc50e
Dev Market Factory:      0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc
Prod Market Factory:     0xA8640B62D755e42C9ed6A86d0fc65CE09e31F264
Dev USDT:                0xCa4f77A38d8552Dd1D5E44e890173921B67725F4
Mainnet USDT:            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
Dev RAIN token:          0x25118290e6A5f4139381D072181157035864099d
Paymaster:               0x5492B6624226F393d0813a8f0bc752B6C0521393
Chainlink BTC/USD:       0x6ce185860a4963106506C203335A2910413708e9
Chainlink ETH/USD:       0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
Chainlink Sequencer:     0xFdB631F5EE196F0ed6FAa767959853A9F217697D
RainEntryPoint:          0x9fFf314ea24b7720714b837419fb324E06e4F398
```

---

## Reference Repos (patterns only — NOT our product)

- `github.com/Quecko-Org/speed-market` — frontend reference (wallet connection, smart accounts, UI patterns)
- `github.com/saifr0/rain-speed-markets` — contract reference (IEntryPoint, subgraph scaffold, fork test patterns)
- `github.com/Quecko-Org/rain-speed-markets` — backend reference (contract service, smart account executor, bet model)
- `github.com/rain1-labs/rain-sdk` — ABIs, transaction builders, market/position queries

---

## How to Report Findings

For every issue found:

```
PHASE: 1-5
FILE: path/to/file
FUNCTION: functionName()
ISSUE: Description of what's wrong
SEVERITY: Critical / High / Medium / Low
FIX: What the fix should be
```

Severity levels:
- **Critical** — funds lost, double-spent, incorrect payouts, or system completely broken
- **High** — system gets into broken state requiring manual intervention
- **Medium** — edge case that will eventually hit in production
- **Low** — missing error handling, logging gaps, code quality

---

## Phase 1 — Contracts

**Status: COMPLETE (23 tests passing)**
**Folder: `contracts/`**
**Stack: Solidity 0.8.29, Foundry, Chainlink Data Feeds + Automation**

### What Was Built
- `ChainlinkResolver` — reads Chainlink price feeds, validates Arbitrum sequencer uptime (1hr grace period), resolves markets via `closePool()` then `chooseWinner()`. Permissionless resolution. Try-catch on chooseWinner (retries on failure, doesn't orphan markets).
- `UpDownAutoCycler` — Chainlink Automation keeper. Creates markets every 5/15/60 min, resolves expired ones. $10 seed liquidity per market. Prunes resolved markets in performUpkeep. Try-catch on createMarket (one failure doesn't halt other timeframes). Multi-pair support (BTC + ETH).
- `ITradePool`, `IFactory` — interfaces extracted from RAIN SDK ABIs.

---

## Phase 2 — Backend Matching Engine

**Status: COMPLETE (32 tests passing)**
**Folder: `backend/`**
**Stack: Node.js, TypeScript, Express, MongoDB, ethers.js, WebSocket (ws)**

### What Was Built
- Off-chain matching engine with price-time priority order book and cancel-before-taker priority
- `DepositService` — monitors USDT Transfer events, deduplicates by txHash, credits MongoDB balances
- `SettlementService` — batched `enterOption()` with exponential backoff retry (max 5), atomic status transitions
- `ClaimService` — claims resolved pools, proportional distribution with dust to relayer, idempotent via claimedByRelayer flag, retry with backoff
- `SignatureService` — EIP-712 order/cancel/withdraw verification
- `MarketSyncer` — polls UpDownAutoCycler, syncs markets + strike prices to MongoDB, broadcasts via WebSocket
- Balance model with atomic `$inc` operations (no read-modify-write race conditions)
- Rate limiting on order submission

### API Endpoints
```
GET    /config              — chain, fees, relayer, EIP-712 domain
GET    /markets             — list markets (?timeframe=300|900|3600, ?pair=BTC-USD|ETH-USD)
GET    /markets/:address    — market detail with best bid/ask, volume, time remaining
POST   /markets/:address/claim — trigger claim for resolved market
GET    /orderbook/:marketId — current order book snapshot
POST   /orders              — place signed order
DELETE /orders/:id          — cancel signed order
GET    /positions/:wallet   — user positions
GET    /trades/:wallet      — trade history (?limit, ?offset)
GET    /balance/:wallet     — balance (available, inOrders, total, withdrawNonce)
POST   /balance/withdraw    — withdraw USDT (signed)
GET    /prices/history/:symbol — proxied price history
GET    /stats               — protocol stats (volume, markets, traders)
WS     /stream              — channels: orderbook:, trades:, markets, orders:, balance:
```

---

## Phase 3 — API Layer

**Status: COMPLETE (merged into Phase 2 backend)**

Added: price history proxy, timeframe/pair filtering on markets, market detail enrichment (best bid/ask, time remaining, strike price), trades endpoint with pagination, stats endpoint, /config endpoint. All in `backend/`.

---

## Phase 4 — Frontend

**Status: COMPLETE**
**Folder: `frontend/`**
**Stack: Next.js 15, React, TypeScript, Tailwind, wagmi, Jotai, Alchemy Account Kit**

### What Was Built
- Home page with 5 min / 15 min / 1 hour sections, BTC/ETH pair tabs
- Market detail page with TradingChart (real price history), TradeForm (UP/DOWN, slider, EIP-712 signing), OrderBook, positions panel
- Wallet connection (MetaMask, WalletConnect, Coinbase) — mirrors speed-market pattern
- Deposit modal (relayer address + QR), withdraw modal (EIP-712 signed)
- Positions page, trade history page
- WebSocket integration for real-time updates with polling fallback
- Kraken design system from DESIGN.md (purple #7132f5, 12px radius, IBM Plex Sans)

### Known Issue
- WalletConnect connection flow doesn't complete reliably — needs debugging. Speed-market's flow works, this one partially works (gets to confirmation but doesn't finish).

---

## Phase 5 — Expand + Harden

**Status: COMPLETE**
**Folders: `sdk/`, `docs/`, updates across all folders**

### What Was Built
- Multi-pair support in UpDownAutoCycler (BTC + ETH cycling concurrently)
- TypeScript bot SDK (`sdk/typescript/`) — HTTP client, WebSocket client, EIP-712 helpers, types
- Python bot SDK (`sdk/python/`) — httpx + websockets client, example taker script
- Rate limiting middleware on backend
- ClaimService retry with exponential backoff
- Frontend: WebSocket stale detection, pair labels, error mapping
- Playwright E2E test scaffolding
- Documentation: `docs/api.md`, `docs/bots/README.md`, `docs/operations.md`, `docs/e2e-checklist.md`
- `contracts/docs/ONCHAIN_OPERATIONS.md` — deployment and configuration guide
