// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal interface for RAIN market factory.
/// Extracted from rain1-labs/rain-sdk CreateMarketAbi.ts.
/// The Params struct field order must match the on-chain ABI exactly.
interface IFactory {
    struct Params {
        bool isPublic;
        bool resolverIsAI;
        address poolOwner;
        address referrer;
        uint256 startTime;
        uint256 endTime;
        uint256 numberOfOptions;
        uint256 oracleEndTime; // dispute duration in seconds (NOT absolute timestamp)
        string ipfsUri;
        uint256 initialLiquidity; // seed USDT in wei — factory requires non-zero
        uint256[] liquidityPercentages; // basis points, must sum to 10000
        address poolResolver;
        address baseToken;
    }

    function createPool(Params calldata params) external returns (address poolInstance);
    function createdPools(address pool) external view returns (bool);
    function totalPools() external view returns (uint256);
}
