// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IVerifierProxy
/// @notice Minimal interface to the Chainlink Data Streams Verifier Proxy.
///         The Verifier Proxy is deployed and operated by Chainlink — see
///         `https://docs.chain.link/data-streams/crypto-streams` for the
///         per-network proxy address table. On Arbitrum Sepolia testnet
///         the proxy is at `0x2ff010DEbC1297f19579B4246cad07bd24F2488A`;
///         the mainnet Arbitrum One address is recorded in dev `.env`
///         under `CHAINLINK_VERIFIER_PROXY_ADDRESS`.
///
///         `verify(payload, parameterPayload)` is the single entry point
///         the resolver consumes. Behavior summary (per the reference
///         implementation at `docs.chain.link/data-streams/tutorials/
///         evm-onchain-report-verification`):
///
///         - `payload` is the opaque signed-report blob returned by the
///           off-chain Data Streams REST API (the `fullReport` field of
///           `GET /api/v1/reports?feedID=...&timestamp=...`).
///         - `parameterPayload` carries the fee token address when the
///           Verifier Proxy's FeeManager is configured (typical on
///           mainnet). When `s_feeManager() == address(0)` (testnet, or
///           subscription-billed deployments) it can be empty bytes.
///         - Returns ABI-encoded report struct. For Crypto streams the
///           consumer decodes as `ReportV3`; for RWA streams, `ReportV8`.
///           UpDown uses Crypto streams (BTC/USD, ETH/USD), so the
///           resolver always decodes as `ReportV3`.
///         - The call is `payable` so it can accept native-fee payment;
///           UpDown pays in LINK, so `msg.value == 0` on every call.
///
///         The proxy internally validates the signed report's DON
///         signatures, deducts the fee (LINK in our case), and only then
///         returns the decoded data — so a successful return means the
///         report is authentic and paid for.
interface IVerifierProxy {
    /// @notice Returns the address of the currently-configured FeeManager,
    ///         or `address(0)` if fees are not collected (testnets,
    ///         subscription-billed mainnets, etc).
    function s_feeManager() external view returns (address);

    /// @notice Verify a signed report and pay the verification fee.
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}

/// @notice Asset structure used by the FeeManager for fee + reward
///         accounting. The `assetAddress` is the ERC-20 token; `amount`
///         is in token-native units (LINK has 18 decimals).
struct FeeManagerAsset {
    address assetAddress;
    uint256 amount;
}

/// @title IFeeManager
/// @notice Minimal interface to the Chainlink Data Streams FeeManager.
///         Queried from the Verifier Proxy via `s_feeManager()` — the
///         resolver does NOT hold a direct reference. The FeeManager is
///         the source of truth for: (a) which token denominates the fee
///         (LINK address via `i_linkAddress`), (b) where the consumer
///         must approve LINK transfers (`i_rewardManager`), and (c) the
///         exact fee amount for a given (subscriber, report, fee-token)
///         tuple (`getFeeAndReward`).
interface IFeeManager {
    function i_linkAddress() external view returns (address);
    function i_rewardManager() external view returns (address);
    function getFeeAndReward(address subscriber, bytes calldata report, address quoteAddress)
        external
        view
        returns (FeeManagerAsset memory fee, FeeManagerAsset memory reward, uint256 totalDiscount);
}

/// @notice Crypto Streams report layout (schema v3). Returned ABI-encoded
///         by `IVerifierProxy.verify`. Field semantics:
///
///         - `feedId`: 32-byte identifier of the price stream (e.g.
///           BTC/USD, ETH/USD). Resolver pins this against the per-pair
///           `streamsFeedId` mapping.
///         - `validFromTimestamp`: earliest unix-second the report is
///           applicable for. Reports are typically valid from their
///           observation moment.
///         - `observationsTimestamp`: unix-second at which the DON's
///           aggregated observation was finalized. The resolver compares
///           this against the market's `endTime` to ensure the report is
///           "the one that captured the closing price."
///         - `nativeFee` / `linkFee`: amounts charged by the Verifier
///           Proxy when this report is verified. UpDown pays via LINK
///           so `linkFee` is the binding number; cross-referenced
///           against the FeeManager.getFeeAndReward result.
///         - `expiresAt`: latest unix-second the report can still be
///           verified on-chain. Past this, the Verifier Proxy itself
///           rejects the report.
///         - `price`: int192 price of the asset at `observationsTimestamp`,
///           in 8 decimals (matching the legacy Chainlink Data Feeds
///           BTC/USD / ETH/USD scale that UpDown's `strikePrice`
///           comparison already uses).
///         - `bid` / `ask`: spread context. Not used by the resolver;
///           kept for completeness / future use.
struct ReportV3 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    int192 bid;
    int192 ask;
}
