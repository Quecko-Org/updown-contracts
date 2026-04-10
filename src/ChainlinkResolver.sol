// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ITradePool} from "./interfaces/ITradePool.sol";

/// @title ChainlinkResolver
/// @notice Reads Chainlink price feeds on Arbitrum, validates the L2 sequencer,
///         and resolves RAIN UpDown markets by calling closePool() + chooseWinner().
///         Set as the `poolResolver` on every UpDown market so only this contract
///         can call chooseWinner (enforced by the pool's OnlyResolver guard).
///         Resolution is permissionless — anyone can call resolve() since the
///         outcome is deterministic from the Chainlink feed.
contract ChainlinkResolver is Ownable {
    // ── Errors ──────────────────────────────────────────────────────────
    error FeedNotConfigured();
    error SequencerDown();
    error SequencerGracePeriod();
    error StalePrice();
    error MarketNotRegistered();
    error MarketNotExpired();
    error AlreadyResolved();

    // ── Events ──────────────────────────────────────────────────────────
    event FeedConfigured(bytes32 indexed pairId, address feed);
    event MarketRegistered(address indexed pool, bytes32 indexed pairId, int256 strikePrice);
    event MarketResolved(address indexed pool, uint256 winningOption, int256 settlementPrice, int256 strikePrice);
    event AuthorizedCallerSet(address indexed caller, bool authorized);

    // ── Types ───────────────────────────────────────────────────────────
    struct MarketInfo {
        bytes32 pairId;
        int256 strikePrice;
        bool resolved;
    }

    // ── Constants ───────────────────────────────────────────────────────
    uint256 public constant MAX_STALENESS = 1 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 public constant OPTION_UP = 1;
    uint256 public constant OPTION_DOWN = 2;

    // ── State ───────────────────────────────────────────────────────────
    AggregatorV3Interface public immutable sequencerFeed;

    mapping(bytes32 => address) public priceFeeds;
    mapping(address => MarketInfo) public markets;
    mapping(address => bool) public authorizedCallers;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _sequencerFeed,
        bytes32 _btcUsdPairId,
        address _btcUsdFeed,
        bytes32 _ethUsdPairId,
        address _ethUsdFeed
    ) Ownable(_owner) {
        sequencerFeed = AggregatorV3Interface(_sequencerFeed);

        priceFeeds[_btcUsdPairId] = _btcUsdFeed;
        emit FeedConfigured(_btcUsdPairId, _btcUsdFeed);

        if (_ethUsdFeed != address(0)) {
            priceFeeds[_ethUsdPairId] = _ethUsdFeed;
            emit FeedConfigured(_ethUsdPairId, _ethUsdFeed);
        }
    }

    // ── Owner: feed management ──────────────────────────────────────────
    function configureFeed(bytes32 pairId, address feed) external onlyOwner {
        priceFeeds[pairId] = feed;
        emit FeedConfigured(pairId, feed);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }

    // ── Authorized: market registration ─────────────────────────────────
    function registerMarket(address pool, bytes32 pairId, int256 strikePrice) external {
        require(authorizedCallers[msg.sender] || msg.sender == owner(), "unauthorized");
        require(priceFeeds[pairId] != address(0), FeedNotConfigured());

        markets[pool] = MarketInfo({pairId: pairId, strikePrice: strikePrice, resolved: false});
        emit MarketRegistered(pool, pairId, strikePrice);
    }

    // ── Public: price reading ───────────────────────────────────────────
    /// @notice Returns the latest validated price for a pair.
    ///         Reverts if the sequencer is down, in grace period, or price is stale.
    function getPrice(bytes32 pairId) external view returns (int256) {
        _checkSequencer();
        return _getLatestPrice(pairId);
    }

    // ── Public: permissionless resolution ────────────────────────────────
    function resolve(address pool) external {
        MarketInfo storage info = markets[pool];
        require(info.pairId != bytes32(0), MarketNotRegistered());
        require(!info.resolved, AlreadyResolved());
        require(block.timestamp >= ITradePool(pool).endTime(), MarketNotExpired());

        _checkSequencer();
        int256 settlementPrice = _getLatestPrice(info.pairId);

        uint256 winningOption = settlementPrice > info.strikePrice ? OPTION_UP : OPTION_DOWN;

        try ITradePool(pool).closePool() {} catch {}
        try ITradePool(pool).chooseWinner(winningOption) {
            info.resolved = true;
            emit MarketResolved(pool, winningOption, settlementPrice, info.strikePrice);
        } catch {
            // Leave resolved = false so resolve() can be retried after the pool is fixed.
        }
    }

    // ── Internal helpers ────────────────────────────────────────────────
    function _checkSequencer() internal view {
        (, int256 answer,, uint256 startedAt,) = sequencerFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
    }

    function _getLatestPrice(bytes32 pairId) internal view returns (int256) {
        address feed = priceFeeds[pairId];
        if (feed == address(0)) revert FeedNotConfigured();

        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();

        return price;
    }
}
