# Manual E2E checklist (UpDown)

Use a **test wallet** and **relayer USDT deposit** (official funding path—no Aqua).

1. Connect wallet (MetaMask / WalletConnect / Coinbase).
2. **Deposit USDT** on Arbitrum to the relayer address from `GET /config` → `relayerAddress`; wait for balance in the app.
3. Open a **5 min** **BTC-USD** market; confirm **chart** shows BTC spot.
4. Place **$10 UP** (or min size); confirm **position** appears.
5. Wait for expiry; automation resolves via **ChainlinkResolver**; position shows win/loss.
6. **Claim** if applicable; **withdraw** USDT via signed withdrawal.

## Paths to verify

- [ ] UP wins (settlement > strike)
- [ ] DOWN wins (settlement < strike)
- [ ] **Tie** (settlement == strike) → **DOWN** wins (resolver uses strict `>` for UP)
- [ ] **5m / 15m / 60m** timeframes
- [ ] **ETH-USD** market: chart shows **ETH**, correct pair label
- [ ] Multiple concurrent positions
- [ ] Zero balance → order rejected with clear message
- [ ] Max position / limits per backend rules
- [ ] Market expires during pending tx → sensible error

## Automated smoke

- Foundry: `forge test` (unit tests including tie → DOWN).
- Optional: run `sdk/typescript` example against a local API.
