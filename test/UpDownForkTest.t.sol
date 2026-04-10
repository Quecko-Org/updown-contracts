// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests for ChainlinkResolver + UpDownAutoCycler against Arbitrum mainnet
///         Chainlink feeds. Market creation tests use the dev factory.
contract UpDownForkTest is Test {
    // ── Arbitrum mainnet Chainlink addresses ────────────────────────────
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CHAINLINK_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ── RAIN dev addresses ──────────────────────────────────────────────
    address constant DEV_FACTORY = 0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc;
    address constant DEV_USDT = 0xCa4f77A38d8552Dd1D5E44e890173921B67725F4;

    // ── Pair IDs ────────────────────────────────────────────────────────
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    // ── Test state ──────────────────────────────────────────────────────
    ChainlinkResolver resolver;
    UpDownAutoCycler cycler;
    address owner = address(this);
    uint256 seedLiquidity = 10_000_000; // $10 USDT (6 decimals)

    function setUp() public {
        // Fork Arbitrum mainnet — uses ARBITRUM_RPC_URL env var
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        vm.createSelectFork(rpc);

        resolver = new ChainlinkResolver(owner, CHAINLINK_SEQUENCER, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD);

        cycler = new UpDownAutoCycler(owner, address(resolver), DEV_FACTORY, DEV_USDT, seedLiquidity);

        resolver.setAuthorizedCaller(address(cycler), true);

        // Fund cycler with USDT
        deal(DEV_USDT, address(cycler), 1_000_000_000); // $1000
    }

    // ── Test: getPrice reads BTC/USD successfully ───────────────────────
    function test_getPrice() public view {
        int256 price = resolver.getPrice(BTCUSD);
        assertGt(price, 0, "BTC price should be positive");
        // BTC/USD has 8 decimals — price should be > $1000 (1000e8)
        assertGt(price, 1000e8, "BTC price should be > $1000");
        console.log("BTC/USD price:", uint256(price));
    }

    // ── Test: getPrice works for ETH/USD too ────────────────────────────
    function test_getPriceETH() public view {
        int256 price = resolver.getPrice(ETHUSD);
        assertGt(price, 0, "ETH price should be positive");
        assertGt(price, 100e8, "ETH price should be > $100");
        console.log("ETH/USD price:", uint256(price));
    }

    // ── Test: unconfigured feed reverts ─────────────────────────────────
    function test_getPriceUnconfiguredReverts() public {
        bytes32 fakePair = keccak256("FAKE/USD");
        vm.expectRevert(ChainlinkResolver.FeedNotConfigured.selector);
        resolver.getPrice(fakePair);
    }

    // ── Test: sequencer down reverts ────────────────────────────────────
    function test_sequencerDownReverts() public {
        // Deploy a mock sequencer feed that reports "down"
        MockSequencer mockSeq = new MockSequencer(1, block.timestamp);
        ChainlinkResolver resolverDown =
            new ChainlinkResolver(owner, address(mockSeq), BTCUSD, CHAINLINK_BTC_USD, ETHUSD, address(0));

        vm.expectRevert(ChainlinkResolver.SequencerDown.selector);
        resolverDown.getPrice(BTCUSD);
    }

    // ── Test: sequencer grace period reverts ─────────────────────────────
    function test_sequencerGracePeriodReverts() public {
        // Sequencer is up (answer=0) but just restarted (startedAt = now)
        MockSequencer mockSeq = new MockSequencer(0, block.timestamp);
        ChainlinkResolver resolverGrace =
            new ChainlinkResolver(owner, address(mockSeq), BTCUSD, CHAINLINK_BTC_USD, ETHUSD, address(0));

        vm.expectRevert(ChainlinkResolver.SequencerGracePeriod.selector);
        resolverGrace.getPrice(BTCUSD);
    }

    // ── Test: stale price reverts ───────────────────────────────────────
    function test_stalePriceReverts() public {
        // Warp 2 hours into the future — Chainlink feed will be stale
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(ChainlinkResolver.StalePrice.selector);
        resolver.getPrice(BTCUSD);
    }

    // ── Test: resolve before expiry reverts ──────────────────────────────
    function test_resolveBeforeExpiryReverts() public {
        // Register a fake market that hasn't expired
        MockPool mockPool = new MockPool(block.timestamp + 1 hours);
        resolver.registerMarket(address(mockPool), BTCUSD, 50000e8);

        vm.expectRevert(ChainlinkResolver.MarketNotExpired.selector);
        resolver.resolve(address(mockPool));
    }

    // ── Test: resolve unregistered market reverts ────────────────────────
    function test_resolveUnregisteredReverts() public {
        vm.expectRevert(ChainlinkResolver.MarketNotRegistered.selector);
        resolver.resolve(address(0xdead));
    }

    // ── Test: double resolve reverts ────────────────────────────────────
    function test_doubleResolveReverts() public {
        MockPool mockPool = new MockPool(block.timestamp - 1);
        resolver.registerMarket(address(mockPool), BTCUSD, 50000e8);

        resolver.resolve(address(mockPool));

        vm.expectRevert(ChainlinkResolver.AlreadyResolved.selector);
        resolver.resolve(address(mockPool));
    }

    // ── Test: resolve calls closePool + chooseWinner ────────────────────
    function test_resolveCallsCloseAndChoose() public {
        int256 currentPrice = resolver.getPrice(BTCUSD);
        // Set strike below current price so UP wins
        int256 strike = currentPrice - 1000e8;

        MockPool mockPool = new MockPool(block.timestamp - 1);
        resolver.registerMarket(address(mockPool), BTCUSD, strike);

        resolver.resolve(address(mockPool));

        assertTrue(mockPool.closePoolCalled(), "closePool should be called");
        assertTrue(mockPool.chooseWinnerCalled(), "chooseWinner should be called");
        assertEq(mockPool.winner(), resolver.OPTION_UP(), "UP should win when price > strike");
    }

    // ── Test: resolve DOWN wins when price <= strike ────────────────────
    function test_resolveDownWins() public {
        int256 currentPrice = resolver.getPrice(BTCUSD);
        // Set strike way above current price so DOWN wins
        int256 strike = currentPrice + 1000e8;

        MockPool mockPool = new MockPool(block.timestamp - 1);
        resolver.registerMarket(address(mockPool), BTCUSD, strike);

        resolver.resolve(address(mockPool));

        assertEq(mockPool.winner(), resolver.OPTION_DOWN(), "DOWN should win when price <= strike");
    }

    // ── Test: authorized caller can register, random cannot ─────────────
    function test_registerMarketAuth() public {
        address rando = address(0xbabe);

        vm.prank(rando);
        vm.expectRevert("unauthorized");
        resolver.registerMarket(address(0x1), BTCUSD, 50000e8);

        // Owner can register directly
        resolver.registerMarket(address(0x1), BTCUSD, 50000e8);
    }

    // ── Test: checkUpkeep returns true when timeframes need creation ─────
    function test_checkUpkeepReturnsTrue() public {
        // lastCreated is 0 for all timeframes, so all need creation
        (bool needed,) = cycler.checkUpkeep("");
        assertTrue(needed, "upkeep should be needed on fresh deploy");
    }

    // ── Test: pruneResolved removes finalized markets ────────────────────
    function test_pruneResolved() public {
        cycler.pruneResolved();
        assertEq(cycler.activeMarketCount(), 0);
    }

    // ── Test: toggleTimeframe works ─────────────────────────────────────
    function test_toggleTimeframe() public {
        cycler.toggleTimeframe(0, false);
        (uint256 dur,, bool active) = cycler.timeframes(0);
        assertFalse(active, "timeframe 0 should be inactive");
        assertEq(dur, 300, "duration should still be 300");

        cycler.toggleTimeframe(0, true);
        (,, active) = cycler.timeframes(0);
        assertTrue(active, "timeframe 0 should be active again");
    }

    // ── Test: invalid timeframe index reverts ────────────────────────────
    function test_toggleTimeframeInvalidReverts() public {
        vm.expectRevert(UpDownAutoCycler.InvalidTimeframeIndex.selector);
        cycler.toggleTimeframe(5, true);
    }

    // ── Test: setSeedLiquidity works ────────────────────────────────────
    function test_setSeedLiquidity() public {
        cycler.setSeedLiquidity(20_000_000);
        assertEq(cycler.seedLiquidity(), 20_000_000);
    }

    // ── Test: withdrawFunds works ───────────────────────────────────────
    function test_withdrawFunds() public {
        deal(DEV_USDT, address(cycler), 100_000_000);
        uint256 balBefore = IERC20(DEV_USDT).balanceOf(owner);

        cycler.withdrawFunds(DEV_USDT, 50_000_000);

        assertEq(IERC20(DEV_USDT).balanceOf(owner), balBefore + 50_000_000);
    }

    // ── Test: configureFeed owner-only ──────────────────────────────────
    function test_configureFeedOnlyOwner() public {
        address rando = address(0xbabe);
        bytes32 newPair = keccak256("SOL/USD");

        vm.prank(rando);
        vm.expectRevert();
        resolver.configureFeed(newPair, address(0x123));

        // Owner succeeds
        resolver.configureFeed(newPair, address(0x123));
        assertEq(resolver.priceFeeds(newPair), address(0x123));
    }
}

// ── Mock contracts for unit testing ─────────────────────────────────────

contract MockSequencer {
    int256 private _answer;
    uint256 private _startedAt;

    constructor(int256 answer_, uint256 startedAt_) {
        _answer = answer_;
        _startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, _startedAt, block.timestamp, 0);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}

contract MockPool {
    uint256 private _endTime;
    uint256 private _winner;
    bool private _closePoolCalled;
    bool private _chooseWinnerCalled;
    bool private _finalized;

    constructor(uint256 endTime_) {
        _endTime = endTime_;
    }

    function endTime() external view returns (uint256) {
        return _endTime;
    }

    function closePool() external {
        _closePoolCalled = true;
    }

    function chooseWinner(uint256 option) external {
        _chooseWinnerCalled = true;
        _winner = option;
    }

    function claim() external {}

    function poolFinalized() external view returns (bool) {
        return _finalized;
    }

    function poolState() external pure returns (uint8) {
        return 0;
    }

    function winner() external view returns (uint256) {
        return _winner;
    }

    function resolver() external view returns (address) {
        return msg.sender;
    }

    function startTime() external view returns (uint256) {
        return 0;
    }

    function allFunds() external pure returns (uint256) {
        return 0;
    }

    function DISPUTE_WINDOW() external pure returns (uint256) {
        return 0;
    }

    // Test helpers
    function setFinalized(bool f) external {
        _finalized = f;
    }

    function closePoolCalled() external view returns (bool) {
        return _closePoolCalled;
    }

    function chooseWinnerCalled() external view returns (bool) {
        return _chooseWinnerCalled;
    }
}
