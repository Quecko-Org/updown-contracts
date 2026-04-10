// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

bytes32 constant BTCUSD = keccak256("BTC/USD");

contract MockSequencerUp {
    int256 private _answer;
    /// @dev ChainlinkResolver reads the 4th tuple slot as `startedAt` (AggregatorV3 `updatedAt` position).
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
        return (0, _price, block.timestamp, block.timestamp, 0);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice chooseWinner always reverts (e.g. pool state prevents resolution).
contract MockPoolWin {
    uint256 private _endTime;
    uint256 public winner;

    constructor(uint256 endTime_) {
        _endTime = endTime_;
    }

    function endTime() external view returns (uint256) {
        return _endTime;
    }

    function closePool() external {}

    function chooseWinner(uint256 option) external {
        winner = option;
    }
}

contract MockPoolChooseReverts {
    uint256 private _endTime;

    constructor(uint256 endTime_) {
        _endTime = endTime_;
    }

    function endTime() external view returns (uint256) {
        return _endTime;
    }

    function closePool() external {}

    function chooseWinner(uint256) external pure {
        revert("chooseWinner failed");
    }
}

/// @notice poolFinalized() true for prune path.
contract MockPoolFinalized {
    function poolFinalized() external pure returns (bool) {
        return true;
    }
}

/// @notice New pools from factory — not yet finalized.
contract MockPoolOpen {
    function poolFinalized() external pure returns (bool) {
        return false;
    }
}

contract MockFactoryFail5m {
    /// @notice Reverts only for 5-minute markets so later timeframes still succeed (state rolls back on revert).
    function createPool(IFactory.Params memory p) external returns (address pool) {
        uint256 dur = p.endTime - p.startTime;
        if (dur == 300) revert("factory revert");
        pool = address(new MockPoolOpen());
    }

    function createdPools(address) external pure returns (bool) {
        return false;
    }

    function totalPools() external pure returns (uint256) {
        return 0;
    }
}

contract UpDownAutoCyclerHarness is UpDownAutoCycler {
    constructor(address o, address r, address f, address t, uint256 s) UpDownAutoCycler(o, r, f, t, s) {}

    function harnessPushActive(address pool, uint256 endTime, bytes32 pairId) external {
        _activeMarkets.push(ActiveMarket({pool: pool, endTime: endTime, pairId: pairId}));
    }
}

contract UpDownUnit is Test {
    address owner = address(this);

    function setUp() public {
        vm.warp(1_700_000_000);
    }

    /// @dev Resolver uses strict `>` for UP; tie (`==`) goes to DOWN.
    function test_resolveTieGoesDown() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0));

        MockPoolWin pool = new MockPoolWin(block.timestamp - 1);
        r.registerMarket(address(pool), BTCUSD, 50_000e8);

        r.resolve(address(pool));

        assertEq(pool.winner(), r.OPTION_DOWN());
    }

    function test_resolveChooseWinnerReverts() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0));

        MockPoolChooseReverts pool = new MockPoolChooseReverts(block.timestamp - 1);
        r.registerMarket(address(pool), BTCUSD, 40_000e8);

        r.resolve(address(pool));

        (,, bool resolved) = r.markets(address(pool));
        assertFalse(resolved, "must stay unresolved when chooseWinner reverts");
    }

    function test_performUpkeepPrunesResolved() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0));

        ERC20Mock usdt = new ERC20Mock();
        MockFactoryFail5m factory = new MockFactoryFail5m();
        uint256 seed = 1e18;
        usdt.mint(address(this), seed * 100);
        usdt.approve(address(factory), type(uint256).max);

        UpDownAutoCyclerHarness cycler =
            new UpDownAutoCyclerHarness(owner, address(resolver), address(factory), address(usdt), seed);
        usdt.mint(address(cycler), seed * 100);
        resolver.setAuthorizedCaller(address(cycler), true);

        MockPoolFinalized fin = new MockPoolFinalized();
        cycler.harnessPushActive(address(fin), 0, BTCUSD);

        assertEq(cycler.activeMarketCount(), 1);

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory noCreates = new UpDownAutoCycler.CreateSlot[](0);
        cycler.performUpkeep(abi.encode(empty, noCreates));

        assertEq(cycler.activeMarketCount(), 0, "prune should remove finalized pool");
    }

    function test_createMarketRevertDoesNotHaltUpkeep() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0));

        ERC20Mock usdt = new ERC20Mock();
        MockFactoryFail5m factory = new MockFactoryFail5m();
        uint256 seed = 1e18;
        usdt.mint(address(this), seed * 1000);
        usdt.approve(address(factory), type(uint256).max);

        UpDownAutoCyclerHarness cycler =
            new UpDownAutoCyclerHarness(owner, address(resolver), address(factory), address(usdt), seed);
        usdt.mint(address(cycler), seed * 1000);
        resolver.setAuthorizedCaller(address(cycler), true);

        vm.warp(block.timestamp + 400 days);
        uint256[] memory resolveEmpty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory createAll = new UpDownAutoCycler.CreateSlot[](3);
        createAll[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});
        createAll[1] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 1});
        createAll[2] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 2});

        cycler.performUpkeep(abi.encode(resolveEmpty, createAll));

        assertEq(cycler.activeMarketCount(), 2, "15m and 60m timeframes should still create after 5m fails");
    }
}
