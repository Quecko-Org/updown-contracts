// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal interface for RAIN trade pool (Diamond proxy).
/// Extracted from rain1-labs/rain-sdk TradeMarketsAbi.ts.
interface ITradePool {
    function chooseWinner(uint256 option) external;
    function closePool() external;
    function claim() external;

    function endTime() external view returns (uint256);
    function startTime() external view returns (uint256);
    function poolState() external view returns (uint8);
    function poolFinalized() external view returns (bool);
    function winner() external view returns (uint256);
    function resolver() external view returns (address);
    function allFunds() external view returns (uint256);
    function DISPUTE_WINDOW() external view returns (uint256);
}
