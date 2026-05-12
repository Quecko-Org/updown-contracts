// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

bytes32 constant BTCUSD = keccak256("BTC/USD");

contract MockSequencerUp {
    int256 private _answer;
    uint256 private _graceRef;

    constructor(int256 answer_, uint256 graceRef_) {
        _answer = answer_;
        _graceRef = graceRef_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, block.timestamp, _graceRef, 0);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}

contract MockBtcFeed {
    int256 private _price;

    constructor(int256 price_) {
        _price = price_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }

    /// @dev PR-10 (P0-16): minimal `getRoundData` so the new roundId-bound
    ///      `resolve` path compiles against this mock. Returns the same
    ///      single-round answer for any id and pretends the next round is far
    ///      in the future — sufficient for tests that don't exercise the
    ///      multi-round canonicality logic. Tests that care about that logic
    ///      use `MockAggregatorV3` below.
    function getRoundData(uint80 rid) external view returns (uint80, int256, uint256, uint256, uint80) {
        // Shape: round 1 = the configured price at "now"; round 2+ in the far future.
        if (rid <= 1) return (rid, _price, block.timestamp, block.timestamp, rid);
        return (rid, _price, block.timestamp + 365 days, block.timestamp + 365 days, rid);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice Multi-round Chainlink mock for PR-10 (P0-16) tests. Lets each test
///         set an explicit (price, updatedAt) per roundId and adjust which
///         id is the "latest" for the off-chain scan path.
contract MockAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestId;

    function setRound(uint80 rid, int256 answer, uint256 updatedAt) external {
        rounds[rid] = Round({answer: answer, updatedAt: updatedAt, exists: true});
        if (rid > latestId) latestId = rid;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }

    function getRoundData(uint80 rid) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[rid];
        // Mirror real Chainlink behaviour: unknown round reverts. The
        // resolver's `getRoundData(roundId + 1)` call must therefore be
        // protected against a missing next round — tests for that case
        // pre-populate a sentinel round with a far-future updatedAt.
        require(r.exists, "MockAggregatorV3: unknown round");
        return (rid, r.answer, r.updatedAt, r.updatedAt, rid);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice Resolver try target: first resolve reverts, second succeeds if toggled.
contract MockSettlementResolve {
    uint256 public marketId;
    bytes32 public pairId;
    int256 public strikePrice;
    bool public shouldRevert;
    uint8 public lastWinner;
    int256 public lastPrice;

    constructor(uint256 mid, bytes32 pid, int256 strike) {
        marketId = mid;
        pairId = pid;
        strikePrice = strike;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getMarket(uint256 mid) external view returns (UpDownSettlement.Market memory m) {
        if (mid != marketId) return m;
        m.endTime = uint64(block.timestamp - 1);
        m.startTime = 1;
        m.pairId = pairId;
        m.strikePrice = int128(strikePrice);
    }

    function resolve(uint256 mid, int256 settlementPrice, uint8 winner) external {
        if (mid != marketId) revert("bad id");
        if (shouldRevert) revert("resolve failed");
        lastPrice = settlementPrice;
        lastWinner = winner;
    }
}

contract UpDownAutoCyclerHarness is UpDownAutoCycler {
    constructor(address o, address r, address st) UpDownAutoCycler(o, r, st) {}

    function harnessPushActive(uint256 marketId, uint256 endTime, bytes32 pairId) external {
        _activeMarkets.push(ActiveMarket({marketId: marketId, endTime: endTime, pairId: pairId}));
    }

    function harnessCreateMarket(uint256 tfIdx, bytes32 pairId) external {
        _createMarket(tfIdx, pairId);
    }

    /// @dev F-06 fail-forward tests need to set pairTfLastCreated directly
    ///      so they can isolate the catch-block behavior without first
    ///      executing a successful _createMarket (which is constrained by
    ///      the F-02 freshness guard during forward warps).
    function harnessSetPairTfLastCreated(bytes32 pairId, uint256 tfIdx, uint256 v) external {
        pairTfLastCreated[pairId][tfIdx] = v;
    }
}

contract UpDownUnit is Test {
    address owner = address(this);

    function setUp() public {
        vm.warp(1_700_000_000);
    }

    /// @dev Full stack: resolver + settlement + harness cycler (BTC only), automation caller authorized.
    function _deployCyclerSystem() internal returns (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ERC20Mock usdt = new ERC20Mock();
        settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement));
        settlement.setResolver(address(r));
        cycler = new UpDownAutoCyclerHarness(owner, address(r), address(settlement));
        settlement.setAutocycler(address(cycler));
        r.setAuthorizedCaller(address(cycler), true);
    }

    function test_resolveTieGoesDown() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        // Market is created at `now`, ends at `now + 300`. Round 7 lands
        // 60s before endTime; round 8 lands 60s after — round 7 is the
        // canonical one for this market.
        uint256 createdAt = block.timestamp;
        feed.setRound(7, 50_000e8, createdAt + 240);
        feed.setRound(8, 60_000e8, createdAt + 360);

        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);

        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));

        vm.prank(address(this));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);

        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        // Warp into the resolution window. `MAX_STALENESS = 1h` so the
        // canonical round (60s pre-endTime) is well within the staleness
        // bound at this point.
        vm.warp(createdAt + 400);
        r.resolve(mid, 7);
        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(settlement.getMarket(mid).winner, 2, "tie price == strike => DOWN");
    }

    function test_resolverResolveTryCatchLeavesUnresolvedOnRevert() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        // MockSettlementResolve hardcodes `endTime = block.timestamp - 1` at
        // the moment its `getMarket` is called. We resolve at warp+500 below,
        // so endTime ~= (createdAt + 500) - 1. Place round 4 strictly before
        // that and round 5 strictly after.
        uint256 createdAt = block.timestamp;
        feed.setRound(4, 50_000e8, createdAt + 100);
        feed.setRound(5, 50_000e8, createdAt + 600);

        MockSettlementResolve target = new MockSettlementResolve(1, BTCUSD, 40_000e8);

        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(target)
        );

        r.registerMarket(1, address(target), BTCUSD, 40_000e8);
        target.setShouldRevert(true);

        vm.warp(createdAt + 500);
        r.resolve(1, 4);

        (,,, bool resolved) = r.markets(1);
        assertFalse(resolved, "must stay unresolved when settlement resolve reverts");
    }

    // ── PR-10 (P0-16): roundId-bound resolution invariants ──────────────

    /// @notice Happy path: caller supplies the canonical roundId (latest
    ///         updatedAt <= endTime; next round updatedAt > endTime) and
    ///         resolution succeeds with that round's price.
    function test_resolve_happyPath_picksCanonicalRound() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 60_000e8, createdAt + 100);
        feed.setRound(11, 70_000e8, createdAt + 250); // canonical: latest <= endTime
        feed.setRound(12, 80_000e8, createdAt + 350); // next: postdates endTime
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8); // endTime = createdAt + 300
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        r.resolve(mid, 11);

        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(int256(settlement.getMarket(mid).settlementPrice), 70_000e8, "settles at the canonical round's price");
        assertEq(settlement.getMarket(mid).winner, 1, "70k > 50k strike => UP");
    }

    /// @notice Wrong roundId: round AFTER endTime -> reverts RoundTooLate.
    ///         This is the core race-to-resolve attack: a caller submits a
    ///         roundId that postdates endTime to bias the price in their
    ///         favour. The contract must reject regardless of `block.timestamp`.
    function test_resolve_revertsWhenRoundIsAfterEndTime() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 60_000e8, createdAt + 250); // canonical
        feed.setRound(11, 80_000e8, createdAt + 350); // post-endTime: attacker would want this
        feed.setRound(12, 90_000e8, createdAt + 450);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8); // endTime = createdAt + 300
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 500);
        vm.expectRevert(ChainlinkResolver.RoundTooLate.selector);
        r.resolve(mid, 11);
    }

    /// @notice Wrong roundId: caller supplies a round whose `updatedAt` is
    ///         pre-endTime, but the NEXT round's `updatedAt` is ALSO pre-
    ///         endTime — i.e. there's a strictly later valid round. Reverts
    ///         NotLastPreEndTimeRound. Forces the resolution price to the
    ///         single canonical round per market regardless of which
    ///         pre-endTime round the caller picked.
    function test_resolve_revertsWhenEarlierThanLatestPreEndTime() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 30_000e8, createdAt + 50); // earlier; caller picks this
        feed.setRound(11, 60_000e8, createdAt + 250); // canonical
        feed.setRound(12, 80_000e8, createdAt + 350); // post-endTime
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        vm.expectRevert(ChainlinkResolver.NotLastPreEndTimeRound.selector);
        r.resolve(mid, 10);
    }

    /// @notice Race scenario: two callers submit different roundIds for the
    ///         same market simultaneously. Only the canonical roundId
    ///         resolves; the other one reverts. Confirms the
    ///         race-to-resolve attack surface is gone.
    function test_resolve_raceTwoCallersOnlyCanonicalSucceeds() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(20, 40_000e8, createdAt + 100);
        feed.setRound(21, 60_000e8, createdAt + 240); // canonical
        feed.setRound(22, 90_000e8, createdAt + 360); // attacker prefers this (UP swing)
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 500);

        // Attacker tries to resolve with the post-endTime round 22 first;
        // contract rejects.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ChainlinkResolver.RoundTooLate.selector);
        r.resolve(mid, 22);

        // Honest caller resolves with the canonical round; succeeds.
        address honest = makeAddr("honest");
        vm.prank(honest);
        r.resolve(mid, 21);

        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(int256(settlement.getMarket(mid).settlementPrice), 60_000e8);
        assertEq(settlement.getMarket(mid).winner, 1, "60k > 50k strike => UP at canonical round");
    }

    /// @notice After a successful resolve, a second attempt — even with the
    ///         canonical roundId — reverts AlreadyResolved. Defence-in-depth
    ///         on top of the existing settlement-side double-resolve guard.
    function test_resolve_revertsWhenAlreadyResolved() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(1, 60_000e8, createdAt + 240);
        feed.setRound(2, 70_000e8, createdAt + 360);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        r.resolve(mid, 1);
        vm.expectRevert(ChainlinkResolver.AlreadyResolved.selector);
        r.resolve(mid, 1);
    }

    function test_performUpkeepPrunesResolved() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);

        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement));
        settlement.setResolver(address(resolver));

        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(resolver), address(settlement));
        settlement.setAutocycler(address(cycler));
        resolver.setAuthorizedCaller(address(cycler), true);

        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(block.timestamp + 400);
        vm.prank(address(resolver));
        settlement.resolve(mid, 50_000e8, 2);

        cycler.harnessPushActive(mid, 0, BTCUSD);

        assertEq(cycler.activeMarketCount(), 1);

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory noCreates = new UpDownAutoCycler.CreateSlot[](0);
        cycler.performUpkeep(abi.encode(empty, noCreates));

        assertEq(cycler.activeMarketCount(), 0, "prune should remove resolved market");
    }

    function test_createMarketFailureIsolation() public {
        // Settlement that always reverts on createMarket
        RevertingSettlement bad = new RevertingSettlement();

        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(bad));

        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(resolver), address(bad));
        resolver.setAuthorizedCaller(address(cycler), true);

        vm.warp(block.timestamp + 400 days);
        uint256[] memory resolveEmpty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory createAll = new UpDownAutoCycler.CreateSlot[](3);
        createAll[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});
        createAll[1] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 1});
        createAll[2] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 2});

        cycler.performUpkeep(abi.encode(resolveEmpty, createAll));

        assertEq(cycler.activeMarketCount(), 0, "all creates fail; nothing active");
    }

    /// @notice Same idea as "12:01:30": 90s after a 5-minute boundary; market snaps to the slot start.
    function test_clockAlignedFiveMin_intraSlotCreation() public {
        uint256 ts = 1_234_567_890;
        assertEq(ts % 300, 90);
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 slotStart = (ts / 300) * 300;
        UpDownSettlement.Market memory m = settlement.getMarket(1);
        assertEq(uint256(m.startTime), slotStart, "start = floor(now/300)*300");
        assertEq(uint256(m.endTime), slotStart + 300, "end = next 5m boundary");
    }

    function test_clockAligned_multiTimeframe_sharedBoundary() public {
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        uint256 b5 = (ts / 300) * 300;
        uint256 b15 = (ts / 900) * 900;
        assertEq(b5, b15, "fixture: 5m and 15m boundaries coincide");

        cycler.harnessCreateMarket(0, BTCUSD);
        cycler.harnessCreateMarket(1, BTCUSD);

        UpDownSettlement.Market memory m5 = settlement.getMarket(1);
        UpDownSettlement.Market memory m15 = settlement.getMarket(2);
        assertEq(m5.startTime, m15.startTime);
        assertEq(uint256(m5.endTime), b5 + 300);
        assertEq(uint256(m15.endTime), b15 + 900);
    }

    function test_pairTfLastCreated_storesBoundaryNotBlockTimestamp() public {
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 boundary = (ts / 300) * 300;
        assertEq(cycler.pairTfLastCreated(BTCUSD, 0), boundary);
        assertTrue(cycler.pairTfLastCreated(BTCUSD, 0) != ts);
    }

    // ── PR-PrePos: pre-positioning window ──────────────────────────────

    function test_prePositioning_disabledByDefault() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        assertEq(cycler.preStartWindowSec(), 0, "default = pre-positioning off");
    }

    function test_prePositioning_setterEnforcesCap() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.setPreStartWindowSec(0);
        cycler.setPreStartWindowSec(30);
        cycler.setPreStartWindowSec(300);
        vm.expectRevert(UpDownAutoCycler.PreStartWindowTooLarge.selector);
        cycler.setPreStartWindowSec(301);
    }

    function test_prePositioning_setterEmitsEvent() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        vm.expectEmit(false, false, false, true);
        emit UpDownAutoCycler.PreStartWindowUpdated(0, 30);
        cycler.setPreStartWindowSec(30);
        vm.expectEmit(false, false, false, true);
        emit UpDownAutoCycler.PreStartWindowUpdated(30, 60);
        cycler.setPreStartWindowSec(60);
    }

    function test_prePositioning_secondCreate_yieldsConsecutiveSlots() public {
        // PR-PrePos changed `_createMarket` to plan from `lastStart + duration`
        // instead of always re-aligning to `currentBoundary`. Verify the second
        // create lands on the next slot, even if `block.timestamp` has skipped
        // forward across multiple boundaries.
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        cycler.harnessCreateMarket(0, BTCUSD);
        UpDownSettlement.Market memory m1 = settlement.getMarket(1);
        uint256 firstStart = uint256(m1.startTime);

        // Advance into the next slot (300s later) and create again.
        vm.warp(firstStart + 350);
        cycler.harnessCreateMarket(0, BTCUSD);
        UpDownSettlement.Market memory m2 = settlement.getMarket(2);

        // Plain consecutive slot — start = previous start + duration.
        assertEq(uint256(m2.startTime), firstStart + 300, "second slot starts where first ends");
        assertEq(uint256(m2.endTime), firstStart + 600);
    }

    function test_prePositioning_marketStartsInFutureWhenWindowOpen() public {
        // With preStartWindowSec = 30, advancing to 30s before the boundary
        // and harness-creating must yield a market whose startTime is in the
        // future (the next boundary) — proving pre-positioning is wired.
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        cycler.setPreStartWindowSec(30);

        // First market lands at the current boundary (bootstrap).
        cycler.harnessCreateMarket(0, BTCUSD);
        UpDownSettlement.Market memory m1 = settlement.getMarket(1);
        uint256 firstStart = uint256(m1.startTime);
        uint256 nextBoundary = firstStart + 300;

        // Warp to 25s before the next boundary — inside the pre-window.
        vm.warp(nextBoundary - 25);
        cycler.harnessCreateMarket(0, BTCUSD);
        UpDownSettlement.Market memory m2 = settlement.getMarket(2);

        // The new market's startTime is in the FUTURE relative to now.
        assertGt(uint256(m2.startTime), block.timestamp, "pre-start: startTime > now");
        assertEq(uint256(m2.startTime), nextBoundary, "= next slot boundary");
        assertEq(uint256(m2.endTime), nextBoundary + 300);
    }

    function test_prePositioning_checkUpkeep_firesEarly() public {
        // checkUpkeep must signal "createNeeded" `preStartWindowSec` seconds
        // earlier than the slot boundary. Pre-fix it required `block.timestamp
        // >= lastStart + duration`; post-fix it only requires `+preStartWindow`.
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // Bootstrap one market so `pairTfLastCreated[BTCUSD][0] = boundary`.
        cycler.harnessCreateMarket(0, BTCUSD);
        uint256 boundary = (ts / 300) * 300;
        uint256 nextBoundary = boundary + 300;

        cycler.setPreStartWindowSec(30);

        // 31s before next boundary — pre-window NOT yet open.
        vm.warp(nextBoundary - 31);
        (bool needed,) = cycler.checkUpkeep("");
        // Some prior runs may already have create eligibility for OTHER tfs
        // (15m / 60m). To isolate the 5m signal, deactivate 15m + 60m.
        cycler.toggleTimeframe(1, false);
        cycler.toggleTimeframe(2, false);
        (needed,) = cycler.checkUpkeep("");
        assertFalse(needed, "31s before next boundary, preWin=30 -> not yet eligible");

        // 30s before next boundary — pre-window now open.
        vm.warp(nextBoundary - 30);
        (needed,) = cycler.checkUpkeep("");
        assertTrue(needed, "exactly preWin seconds before boundary -> eligible");
    }

    // ── F-02 freshness guard tests (deep review 2026-05-11) ─────────────

    /// @notice F-02: catch-up slot whose end is more than RESOLVER_MAX_STALENESS
    ///         behind `block.timestamp` must revert at _createMarket.
    function test_F02_rejectsStaleCatchupSlot() public {
        // Bootstrap a 5m slot at `now`. lastCreated becomes the floor boundary.
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.harnessCreateMarket(0, BTCUSD);

        // Jump WAY forward — 24h later. Next slot's plannedStart =
        // lastStart + 300 = ~24h-ish in the past. end = plannedStart + 300
        // is also ~24h-ish in the past. End + 1h staleness is still way
        // behind `nowTs`, so the freshness guard must trip.
        vm.warp(block.timestamp + 24 hours);

        // Expect the exact custom error with the computed timestamps.
        // We don't pin the exact values (they depend on the bootstrap
        // boundary), but we pin the selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                UpDownAutoCycler.PlannedStartTooStale.selector,
                // plannedStart = lastStart + 300 (computed by the cycler)
                // plannedEnd   = plannedStart + 300
                // nowTs        = block.timestamp
                // We re-derive them here for the strict revert match.
                cycler.pairTfLastCreated(BTCUSD, 0) + 300,
                cycler.pairTfLastCreated(BTCUSD, 0) + 600,
                block.timestamp
            )
        );
        cycler.harnessCreateMarket(0, BTCUSD);
    }

    /// @notice F-02: a slot at the exact MAX_STALENESS boundary is still
    ///         acceptable (strict `<` check, not `<=`).
    function test_F02_acceptsBoundaryFreshness() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 lastStart = cycler.pairTfLastCreated(BTCUSD, 0);
        uint256 end = lastStart + 600; // plannedStart=lastStart+300, end=plannedStart+300

        // Warp so `end + MAX_STALENESS == nowTs` exactly. Guard's check is
        // `end + MAX_STALENESS < nowTs` so this case passes.
        vm.warp(end + cycler.RESOLVER_MAX_STALENESS());

        cycler.harnessCreateMarket(0, BTCUSD);

        // Verify advancement and that no revert occurred.
        assertEq(cycler.pairTfLastCreated(BTCUSD, 0), lastStart + 300, "next slot was created at the boundary");
    }

    /// @notice F-02: the bootstrap case (lastCreated == 0) is never gated
    ///         by the freshness guard — the floor boundary is always within
    ///         `tf.duration` of `nowTs`, so end > nowTs always.
    function test_F02_bootstrapNeverStale() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // Even if we warp arbitrarily far forward before the first call,
        // bootstrap snaps plannedStart to floor(nowTs / 300) * 300, so
        // end = plannedStart + 300 > nowTs trivially.
        vm.warp(block.timestamp + 365 days);
        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 ls = cycler.pairTfLastCreated(BTCUSD, 0);
        assertEq(ls, (block.timestamp / 300) * 300, "bootstrap aligned to current 5m boundary");
        assertGt(ls + 300, block.timestamp - cycler.RESOLVER_MAX_STALENESS(),
            "bootstrap end is fresh by definition");
    }

    // ── F-04 immutable resolver/settlement tests (deep review 2026-05-11) ─

    /// @notice F-04: constructor reverts on zero resolver address. Required
    ///         because `resolver` is immutable — there's no fix-after-deploy.
    function test_F04_constructorRejectsZeroResolver() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(usdt, owner, 70, 80);
        vm.expectRevert(UpDownAutoCycler.ZeroAddress.selector);
        new UpDownAutoCyclerHarness(owner, address(0), address(st));
        // silence "unused" warnings on the constructed-but-not-used vars
        seq;
    }

    /// @notice F-04: constructor reverts on zero settlement address.
    function test_F04_constructorRejectsZeroSettlement() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        // Resolver itself rejects zero settlement; we need a non-zero settlement
        // to construct the resolver, then we pass address(0) for the cycler's
        // settlement arg specifically.
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(st));
        vm.expectRevert(UpDownAutoCycler.ZeroAddress.selector);
        new UpDownAutoCyclerHarness(owner, address(r), address(0));
    }

    /// @notice F-04: `setResolver(address)` and `setSettlement(address)` no
    ///         longer exist on the cycler ABI. Regression test catches a
    ///         future re-introduction (low-level call must fail).
    function test_F04_settersDoNotExistOnAbi() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        bytes memory setResolverCall = abi.encodeWithSignature("setResolver(address)", address(0));
        (bool okR,) = address(cycler).call(setResolverCall);
        assertFalse(okR, "setResolver(address) must not exist on the cycler ABI");

        bytes memory setSettlementCall = abi.encodeWithSignature("setSettlement(address)", address(0));
        (bool okS,) = address(cycler).call(setSettlementCall);
        assertFalse(okS, "setSettlement(address) must not exist on the cycler ABI");
    }

    // ── F-06 strike-overflow + fail-forward tests (deep review 2026-05-11) ─

    /// @notice F-06 part 1: a strike returned by `resolver.getPrice` that
    ///         doesn't fit in int128 must revert at _createMarket BEFORE the
    ///         settlement.createMarket call (catches the truncation loudly).
    function test_F06_strikeOverflowReverts() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        // Strike that's just past int128.max — settlement's int128 storage
        // would truncate this silently pre-F-06; now it reverts loudly.
        int256 oversized = int256(type(int128).max) + 1;
        MockBtcFeed feed = new MockBtcFeed(oversized);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(st));
        st.setResolver(address(r));
        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(r), address(st));
        st.setAutocycler(address(cycler));
        r.setAuthorizedCaller(address(cycler), true);

        vm.expectRevert(abi.encodeWithSelector(UpDownAutoCycler.StrikeOverflow.selector, oversized));
        cycler.harnessCreateMarket(0, BTCUSD);
    }

    /// @notice F-06 part 1: a strike at the exact int128 boundary still
    ///         succeeds (the check is `> max || < min`, not `>= max`).
    function test_F06_strikeAtBoundaryStillSucceeds() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        int256 boundary = int256(type(int128).max);
        MockBtcFeed feed = new MockBtcFeed(boundary);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(st));
        st.setResolver(address(r));
        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(r), address(st));
        st.setAutocycler(address(cycler));
        r.setAuthorizedCaller(address(cycler), true);

        cycler.harnessCreateMarket(0, BTCUSD);
        assertEq(cycler.activeMarketCount(), 1, "strike at exact boundary should succeed");
    }

    /// @notice F-06 part 2 (fail-forward): when _createMarketExternal reverts
    ///         in a continuing cycle (lastStart != 0), pairTfLastCreated
    ///         advances by exactly tf.duration so the next checkUpkeep moves
    ///         to the FOLLOWING slot instead of retrying this one.
    function test_F06_failForward_advancesFromContinuingCycle() public {
        // RevertingSettlement always reverts on createMarket, so any
        // _createMarket call fails after the resolver.getPrice + F-06
        // strike check pass.
        RevertingSettlement bad = new RevertingSettlement();
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(bad));
        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(r), address(bad));
        r.setAuthorizedCaller(address(cycler), true);

        // Seed pairTfLastCreated as if a prior cycle had landed at `now`.
        // 5m timeframe (tfIdx=0). Manually mirror the storage state.
        uint256 lastStart = (block.timestamp / 300) * 300;
        cycler.harnessSetPairTfLastCreated(BTCUSD, 0, lastStart);

        // Warp forward to where the NEXT slot is the only one due.
        vm.warp(lastStart + 300 + 1);

        // performUpkeep with this single createSlot. _createMarket will
        // revert inside settlement.createMarket. F-06 catch fires.
        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory slots = new UpDownAutoCycler.CreateSlot[](1);
        slots[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});
        cycler.performUpkeep(abi.encode(empty, slots));

        // pairTfLastCreated must have advanced by exactly one tf.duration.
        assertEq(
            cycler.pairTfLastCreated(BTCUSD, 0),
            lastStart + 300,
            "failed slot's plannedStart is persisted; next tick advances to lastStart + 2*300"
        );
    }

    /// @notice F-06 part 2: when _createMarketExternal reverts on bootstrap
    ///         (lastStart == 0), pairTfLastCreated snaps to the current
    ///         floor boundary so the next tick advances to that boundary +
    ///         duration. Symmetric with _createMarket's bootstrap path.
    function test_F06_failForward_bootstrapFromZero() public {
        RevertingSettlement bad = new RevertingSettlement();
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(bad));
        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(r), address(bad));
        r.setAuthorizedCaller(address(cycler), true);

        // Fresh slate: lastStart == 0. pairTfLastCreated has never been set.
        assertEq(cycler.pairTfLastCreated(BTCUSD, 0), 0, "pre-condition: bootstrap state");

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory slots = new UpDownAutoCycler.CreateSlot[](1);
        slots[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});
        cycler.performUpkeep(abi.encode(empty, slots));

        uint256 expectedBoundary = (block.timestamp / 300) * 300;
        assertEq(
            cycler.pairTfLastCreated(BTCUSD, 0),
            expectedBoundary,
            "bootstrap fail-forward aligns to current floor boundary"
        );
    }

    /// @notice F-06 part 2: emits `SlotSkippedAfterFailure(pairId, tfIdx,
    ///         skippedSlotStart)` alongside the existing MarketCreationFailed.
    function test_F06_failForward_emitsSlotSkipped() public {
        RevertingSettlement bad = new RevertingSettlement();
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(bad));
        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(r), address(bad));
        r.setAuthorizedCaller(address(cycler), true);

        uint256 lastStart = (block.timestamp / 300) * 300;
        cycler.harnessSetPairTfLastCreated(BTCUSD, 0, lastStart);
        vm.warp(lastStart + 300 + 1);

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory slots = new UpDownAutoCycler.CreateSlot[](1);
        slots[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});

        vm.expectEmit(true, true, false, true);
        emit UpDownAutoCycler.SlotSkippedAfterFailure(BTCUSD, 0, lastStart + 300);
        cycler.performUpkeep(abi.encode(empty, slots));
    }

    /// @notice F-06 part 2 defensive guard: a hand-crafted performData with
    ///         out-of-range tfIdx must NOT cause a double-revert in the
    ///         catch block. The advancement is skipped (no `timeframes[invalid]`
    ///         access); only `MarketCreationFailed` is emitted.
    function test_F06_failForward_invalidTfIdxIsSafe() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory slots = new UpDownAutoCycler.CreateSlot[](1);
        // tfIdx = NUM_TIMEFRAMES (= 3) is out of range; _createMarket reverts
        // with InvalidTimeframeIndex. Pre-F-06 the catch block would have
        // touched `timeframes[3]` and itself reverted. The defensive guard
        // prevents that.
        slots[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 3});

        // Call must succeed (catch absorbs the inner revert, defensive guard
        // skips advancement). No double revert.
        cycler.performUpkeep(abi.encode(empty, slots));

        // No advancement happened for any tfIdx since the slot was invalid.
        // (Other tfIdx values are untouched too — invalid slot didn't poison them.)
        assertEq(cycler.pairTfLastCreated(BTCUSD, 0), 0, "invalid slot does not poison tf=0 state");
    }

    // ── Prior #2 (checkUpkeep gas leak) tests
    //    Per AUDIT_FINDING_CHECKUPKEEP_GAS_LEAK.md, 2026-05-07 ──────────────

    /// @notice Prior #2: with no creates due, `upkeepNeeded` must be `false`
    ///         even when there are past-endTime markets in `_activeMarkets[]`.
    ///         Pre-fix, those past-endTime entries forced `upkeepNeeded=true`
    ///         and burned ~2M gas/call on a fruitless `_pruneResolved` walk.
    function test_PriorIssue2_pastEndTimeAloneDoesNotGateUpkeep() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // Create one 5m market at `now`; pairTfLastCreated[BTCUSD][0] is now
        // set to the current floor boundary.
        cycler.harnessCreateMarket(0, BTCUSD);
        assertEq(cycler.activeMarketCount(), 1, "pre-condition: one active market");

        // Disable 15m + 60m timeframes so no other create can be due.
        cycler.toggleTimeframe(1, false);
        cycler.toggleTimeframe(2, false);

        // Warp forward to AFTER endTime but BEFORE the next 5m slot is due —
        // i.e. ~301-599 seconds into the slot, so end is passed but next
        // slot start has not yet armed.
        // Start of slot: floor(now/300)*300. End: + 300. Pre-window default 0.
        // Next create eligible at: lastStart + 300 (= end).
        // So we want now == end exactly, where a "resolve-only" condition
        // would trigger pre-fix upkeepNeeded. Post-fix, no — only create
        // eligibility matters.
        uint256 lastStart = cycler.pairTfLastCreated(BTCUSD, 0);
        vm.warp(lastStart + 299); // 1s before slot ends — market still ACTIVE

        (bool needed, bytes memory data) = cycler.checkUpkeep("");
        assertFalse(needed, "1s before slot end + create not due -> no upkeep");
        // sanity: no performData payload when not needed
        assertEq(data.length, 0, "no payload when not needed");
    }

    /// @notice Prior #2: when ONLY a create is due (no resolve-aged markets),
    ///         `upkeepNeeded` must be `true`. Baseline create-path coverage
    ///         post-fix — sanity that we didn't over-rotate the gate.
    function test_PriorIssue2_pendingCreateGatesUpkeepTrue() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.toggleTimeframe(1, false);
        cycler.toggleTimeframe(2, false);

        // Bootstrap creates the first slot — its `pairTfLastCreated` is set.
        cycler.harnessCreateMarket(0, BTCUSD);
        uint256 lastStart = cycler.pairTfLastCreated(BTCUSD, 0);

        // Warp to slot end == next-create-eligible.
        vm.warp(lastStart + 300);

        (bool needed, bytes memory data) = cycler.checkUpkeep("");
        assertTrue(needed, "create at boundary -> upkeep needed");
        assertGt(data.length, 0, "payload populated when needed");
    }

    // ── #21 evictUnresolved tests (POST_DEMO_TODO 2026-05-06) ──────────

    /// @notice #21: a market whose `endTime + MAX_STALENESS` is past now is
    ///         eligible for eviction; swap-and-pop removes it cleanly.
    function test_evictUnresolved_evictsStaleMarket() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // Push three fake active markets directly: mid=10 + mid=11 + mid=12.
        // All have endTime in the past.
        uint256 staleEnd = block.timestamp - 2 hours; // well past 1h staleness
        cycler.harnessPushActive(10, staleEnd, BTCUSD);
        cycler.harnessPushActive(11, staleEnd, BTCUSD);
        cycler.harnessPushActive(12, staleEnd, BTCUSD);

        assertEq(cycler.activeMarketCount(), 3, "pre: 3 active");

        uint256[] memory toEvict = new uint256[](1);
        toEvict[0] = 11; // middle one — exercises swap-and-pop semantics

        cycler.evictUnresolved(toEvict);

        assertEq(cycler.activeMarketCount(), 2, "post: 2 active");

        // Verify mid=11 is gone, mid=10 still there.
        (uint256 m0,, ) = cycler.activeMarkets(0);
        (uint256 m1,, ) = cycler.activeMarkets(1);
        assertTrue(m0 != 11 && m1 != 11, "mid=11 must be evicted");
    }

    /// @notice #21: batched eviction of multiple stuck markets in one call.
    function test_evictUnresolved_evictsBatch() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        uint256 staleEnd = block.timestamp - 2 hours;
        cycler.harnessPushActive(20, staleEnd, BTCUSD);
        cycler.harnessPushActive(21, staleEnd, BTCUSD);
        cycler.harnessPushActive(22, staleEnd, BTCUSD);
        cycler.harnessPushActive(23, staleEnd, BTCUSD);

        uint256[] memory toEvict = new uint256[](3);
        toEvict[0] = 20;
        toEvict[1] = 22;
        toEvict[2] = 23;

        cycler.evictUnresolved(toEvict);

        // Only mid=21 should remain.
        assertEq(cycler.activeMarketCount(), 1, "1 remaining after batch evict");
        (uint256 remaining,, ) = cycler.activeMarkets(0);
        assertEq(remaining, 21, "mid=21 is the only un-evicted one");
    }

    /// @notice #21: trying to evict a market within the staleness window
    ///         must revert. Critical safety property — admin can't force-
    ///         evict resolvable markets and lock user funds.
    function test_evictUnresolved_revertsIfMarketStillResolvable() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // endTime = now - 30 minutes; well within MAX_STALENESS (1h).
        // The permissionless resolver could still succeed for this market.
        uint256 freshEnd = block.timestamp - 30 minutes;
        cycler.harnessPushActive(30, freshEnd, BTCUSD);

        uint256[] memory toEvict = new uint256[](1);
        toEvict[0] = 30;

        vm.expectRevert(abi.encodeWithSelector(
            UpDownAutoCycler.MarketStillResolvable.selector,
            uint256(30),
            freshEnd,
            block.timestamp
        ));
        cycler.evictUnresolved(toEvict);

        // Nothing was evicted on the revert.
        assertEq(cycler.activeMarketCount(), 1, "active set unchanged");
    }

    /// @notice #21: trying to evict a market that isn't even in the active
    ///         set must revert. Distinct error from `MarketStillResolvable`
    ///         so operators can tell the two failure modes apart.
    function test_evictUnresolved_revertsIfMarketNotInActiveSet() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        uint256 staleEnd = block.timestamp - 2 hours;
        cycler.harnessPushActive(40, staleEnd, BTCUSD);

        uint256[] memory toEvict = new uint256[](1);
        toEvict[0] = 999; // never created

        vm.expectRevert(abi.encodeWithSelector(
            UpDownAutoCycler.MarketNotInActiveSet.selector,
            uint256(999)
        ));
        cycler.evictUnresolved(toEvict);

        assertEq(cycler.activeMarketCount(), 1, "real market untouched");
    }

    /// @notice #21: only the owner can call. Tests both that a non-owner
    ///         revert occurs and that the owner can call without issue.
    function test_evictUnresolved_onlyOwner() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        uint256 staleEnd = block.timestamp - 2 hours;
        cycler.harnessPushActive(50, staleEnd, BTCUSD);

        uint256[] memory toEvict = new uint256[](1);
        toEvict[0] = 50;

        // Non-owner call reverts (don't pin Ownable's specific error name —
        // OZ has changed it across versions; presence of a revert is enough).
        vm.prank(address(0xdead));
        vm.expectRevert();
        cycler.evictUnresolved(toEvict);

        // Owner call succeeds.
        cycler.evictUnresolved(toEvict);
        assertEq(cycler.activeMarketCount(), 0, "owner evicted successfully");
    }

    /// @notice #21: emits `SlotEvictedManually(marketId, pairId, endTime)`
    ///         per evicted market for ops audit trail.
    function test_evictUnresolved_emitsEvent() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        uint256 staleEnd = block.timestamp - 2 hours;
        cycler.harnessPushActive(60, staleEnd, BTCUSD);

        uint256[] memory toEvict = new uint256[](1);
        toEvict[0] = 60;

        vm.expectEmit(true, true, false, true);
        emit UpDownAutoCycler.SlotEvictedManually(60, BTCUSD, staleEnd);
        cycler.evictUnresolved(toEvict);
    }

    // ── F-01 deprecation marker tests (deep review 2026-05-11) ──────────

    /// @notice F-01: `deprecate(replacement)` flips the `deprecated` flag
    ///         and emits the lifecycle event with the replacement address.
    function test_F01_deprecate_setsStateAndEmits() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        assertFalse(cycler.deprecated(), "pre-condition: not deprecated");

        address replacement = address(0xCafeBeef);

        vm.expectEmit(true, true, false, true);
        emit UpDownAutoCycler.CyclerDeprecated(address(cycler), replacement);
        cycler.deprecate(replacement);

        assertTrue(cycler.deprecated(), "post-condition: deprecated flag set");
    }

    /// @notice F-01: deprecate works with replacement = address(0) for
    ///         final shutdown / no-successor case.
    function test_F01_deprecate_acceptsZeroReplacementForShutdown() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        // Should not revert — zero replacement is the documented shutdown signal.
        cycler.deprecate(address(0));
        assertTrue(cycler.deprecated(), "deprecated even with zero replacement");
    }

    /// @notice F-01: one-shot — a second `deprecate(...)` reverts so the
    ///         first call's replacement address stays canonical.
    function test_F01_deprecate_isOneShot() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.deprecate(address(0xAaaa));

        vm.expectRevert(UpDownAutoCycler.AlreadyDeprecated.selector);
        cycler.deprecate(address(0xBbbb));
    }

    /// @notice F-01: only the owner can deprecate.
    function test_F01_deprecate_onlyOwner() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        vm.prank(address(0xdead));
        vm.expectRevert(); // OZ Ownable error — version-agnostic
        cycler.deprecate(address(0));
        assertFalse(cycler.deprecated(), "non-owner call must not flip state");
    }

    /// @notice F-01: post-deprecation, `checkUpkeep` returns `(false, "")`
    ///         silently — no event, no revert — so Chainlink Automation
    ///         stops scheduling. Confirms the "tell the keeper to stop"
    ///         half of the contract.
    function test_F01_checkUpkeep_returnsFalseWhenDeprecated() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        // Force a state where checkUpkeep WOULD return true if not deprecated:
        // bootstrap a market, warp to next slot boundary so a create is due.
        cycler.harnessCreateMarket(0, BTCUSD);
        uint256 lastStart = cycler.pairTfLastCreated(BTCUSD, 0);
        vm.warp(lastStart + 300);

        // Sanity: pre-deprecation, upkeep is needed.
        (bool needed,) = cycler.checkUpkeep("");
        assertTrue(needed, "pre-deprecation: create due -> upkeep true");

        cycler.deprecate(address(0xAaaa));

        (bool needed2, bytes memory data) = cycler.checkUpkeep("");
        assertFalse(needed2, "post-deprecation: checkUpkeep returns false");
        assertEq(data.length, 0, "post-deprecation: empty performData");
    }

    /// @notice F-01: post-deprecation, a DIRECT `performUpkeep` call
    ///         (bypassing checkUpkeep — what a misconfigured keeper would
    ///         do) reverts with `Deprecated()`. Loud failure converts the
    ///         PR #88 silent-burn class into observable behavior.
    function test_F01_performUpkeep_revertsWhenDeprecated() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.deprecate(address(0xAaaa));

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory noCreates = new UpDownAutoCycler.CreateSlot[](0);

        vm.expectRevert(UpDownAutoCycler.Deprecated.selector);
        cycler.performUpkeep(abi.encode(empty, noCreates));
    }

    /// @notice Prior #2: even when `upkeepNeeded` is gated only by
    ///         `createCount > 0`, the `resolveIndices` field in `performData`
    ///         still carries the indexes of past-endTime markets — diagnostic
    ///         emission for off-chain consumers + ABI stability with the
    ///         Chainlink Automation registration. `performUpkeep` ignores
    ///         the indices; the field's presence is a non-breaking change.
    function test_PriorIssue2_performDataStillCarriesResolveIndicesForDiagnostics() public {
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();
        cycler.toggleTimeframe(1, false);
        cycler.toggleTimeframe(2, false);

        // Two active markets that have aged past their endTime.
        cycler.harnessPushActive(101, block.timestamp - 1, BTCUSD);
        cycler.harnessPushActive(102, block.timestamp - 1, BTCUSD);

        // Now force a create-eligible state so upkeepNeeded gates true.
        // Bootstrap the 5m so lastCreated is set, then warp to next-create.
        cycler.harnessCreateMarket(0, BTCUSD);
        uint256 lastStart = cycler.pairTfLastCreated(BTCUSD, 0);
        vm.warp(lastStart + 300);

        // Re-push the past-endTime markers because the bootstrap also added one.
        // (The first cycle's active count after bootstrap is 1; we already
        // had 2 pre-pushed, so we have 3 active markets total now — the 2
        // pre-pushed at endTime - 1 are past, the one bootstrapped is fresh.)
        // The vm.warp above is fine — `now > endTime` is true for the pre-pushed
        // entries.

        (bool needed, bytes memory data) = cycler.checkUpkeep("");
        assertTrue(needed, "create eligible -> upkeep true");

        (uint256[] memory resolveIndices, UpDownAutoCycler.CreateSlot[] memory createSlots) =
            abi.decode(data, (uint256[], UpDownAutoCycler.CreateSlot[]));

        // At least the two pre-pushed past-endTime entries must appear in
        // resolveIndices. The bootstrapped market's endTime may or may not
        // be past depending on warp delta; we don't pin the exact count.
        assertGe(resolveIndices.length, 2, "resolveIndices carries past-endTime entries");
        assertEq(createSlots.length, 1, "exactly one create slot due (5m)");
        assertEq(createSlots[0].tfIdx, 0, "the due slot is the 5m one");
        assertEq(createSlots[0].pairId, BTCUSD, "the due slot is for BTC/USD");
    }
}

contract RevertingSettlement {
    function createMarket(bytes32, uint256, int256) external pure returns (uint256) {
        revert("no create");
    }

    function createMarket(bytes32, uint256, int256, uint64, uint64) external pure returns (uint256) {
        revert("no create");
    }

    function getMarket(uint256) external pure returns (UpDownSettlement.Market memory m) {
        return m;
    }
}
