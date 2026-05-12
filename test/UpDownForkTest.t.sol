// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

/// @notice Fork tests for the Chainlink-feed-driven resolver flow.
///
///         **2026-05-13 Data Streams swap (Gate 1): tests in this file
///         are temporarily empty.** The pre-swap suite exercised the
///         Data Feeds round-scan path (`resolve(marketId, uint80 roundId)`)
///         against the live Arbitrum mainnet BTC/USD aggregator. That
///         entire path is gone post-swap — the resolver now consumes
///         signed `ReportV3` blobs fetched off-chain from the Data
///         Streams REST API, with on-chain verification via the
///         Chainlink VerifierProxy.
///
///         A fork-style end-to-end test re-emerges in **Gate 3** of the
///         Streams swap: deploy the resolver against Arbitrum Sepolia's
///         testnet VerifierProxy (`0x2ff010DEbC1297f19579B4246cad07bd24F2488A`),
///         fetch a real signed BTC/USD report from
///         `api.testnet-dataengine.chain.link/api/v1/reports`, submit it
///         on-chain, and assert the full resolve cycle from off-chain
///         fetch → on-chain `verifierProxy.verify` → LINK fee deduction
///         → `settlement.resolve` round-trip.
///
///         Until then, this file is a placeholder so the suite as a
///         whole still compiles. The unit tests in `UpDownUnit.t.sol`
///         cover the resolver's Streams-side logic with mock
///         VerifierProxy + FeeManager + LinkToken.
contract UpDownForkTest is Test {
    function test_placeholder_streamsForkTestsLiveInGate3() public pure {
        // Intentionally empty. See contract-level docstring.
    }
}
