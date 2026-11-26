// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PrimeHashFixture} from "./utils/PrimeHashFixture.sol";
import {MiningEngine} from "../src/MiningEngine.sol";
import {Emission} from "../src/libraries/Emission.sol";

contract MiningEngineTest is PrimeHashFixture {
    uint256 constant REWARD = 5e18;
    uint256 constant TOL = 1e9; // rounding tolerance (wei)

    // ------------------------------------------------------------------
    // Setup / launch state
    // ------------------------------------------------------------------

    function test_launchState() public view {
        assertTrue(engine.initialized());
        assertEq(engine.startBlock(), 1_000);
        assertEq(engine.totalLiquidity(), 0, "protocol liquidity does not mine");
        assertEq(token.totalSupply(), 210_000e18);
        assertGe(token.balanceOf(address(reserve)), 89_000e18, "at most 21k used at launch, 100k sent as leaderboard bonus");
        assertEq(token.balanceOf(address(this)), 100_000e18, "leaderboard bonus went to the deployer");
        assertEq(reserve.positionCount(), 1);
        assertEq(IERC721(address(posm)).ownerOf(reserve.positions(0)), address(reserve));
    }

    function test_initializeOnlyOnce() public {
        vm.expectRevert(MiningEngine.AlreadyInitialized.selector);
        engine.initialize(key);
    }

    function test_initializeOnlyDeployer() public {
        MiningEngine e = new MiningEngine(posm);
        vm.prank(alice);
        vm.expectRevert(MiningEngine.OnlyDeployer.selector);
        e.initialize(key);
    }

    // ------------------------------------------------------------------
    // PRIME emission
    // ------------------------------------------------------------------

    function test_singleMiner_gets5PrimePerBlock() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(100);

        (uint256 b,) = engine.pending(id);
        assertApproxEqAbs(b, 100 * REWARD, TOL);
        assertEq(engine.miningPowerBps(id), 10_000);

        (uint256 claimed,) = _claim(alice, id);
        assertEq(token.balanceOf(alice) >= claimed, true);
        assertApproxEqAbs(claimed, 100 * REWARD, TOL);
        (b,) = engine.pending(id);
        assertEq(b, 0, "nothing left after claim");
    }

    function test_twoMiners_splitProportionalToLiquidity() public {
        (uint256 a, uint128 la) = _mint(alice, 1 ether, true);
        (uint256 b, uint128 lb) = _mint(bob, 3 ether, true);
        _roll(1000);

        uint256 total = 1000 * REWARD;
        (uint256 pa,) = engine.pending(a);
        (uint256 pb,) = engine.pending(b);
        assertApproxEqAbs(pa, total * la / (uint256(la) + lb), TOL);
        assertApproxEqAbs(pb, total * lb / (uint256(la) + lb), TOL);
        assertApproxEqRel(pb, pa * 3, 0.02e18, "bob ~3x alice");
        assertApproxEqAbs(engine.miningPowerBps(a) + engine.miningPowerBps(b), 10_000, 1);
    }

    function test_lateJoiner_onlyEarnsFromJoin() public {
        (uint256 a,) = _mint(alice, 1 ether, true);
        _roll(100);
        (uint256 b,) = _mint(bob, 1 ether, true);
        _roll(100);

        (uint256 pa,) = engine.pending(a);
        (uint256 pb,) = engine.pending(b);
        assertApproxEqRel(pa, 150 * REWARD, 0.01e18);
        assertApproxEqRel(pb, 50 * REWARD, 0.01e18);
    }

    function test_halving() public {
        uint256 h = engine.startBlock() + Emission.HALVING_INTERVAL;
        vm.roll(h - 10);
        (uint256 id,) = _mint(alice, 1 ether, true);
        (uint256 r, uint256 next) = engine.currentReward();
        assertEq(r, REWARD);
        assertEq(next, h);

        vm.roll(h + 10);
        (r, next) = engine.currentReward();
        assertEq(r, REWARD / 2);
        assertEq(next, h + Emission.HALVING_INTERVAL);

        (uint256 p,) = engine.pending(id);
        assertApproxEqAbs(p, 10 * REWARD + 10 * REWARD / 2, TOL);
    }

    function test_noMiners_emissionIsNotMinted() public {
        _roll(1000); // nobody mining
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(10);
        (uint256 p,) = engine.pending(id);
        assertApproxEqAbs(p, 10 * REWARD, TOL, "the 1000 empty blocks are lost");
    }

    // ------------------------------------------------------------------
    // ETH rewards
    // ------------------------------------------------------------------

    function test_ethFee_isStreamedToMiners() public {
        (uint256 id,) = _mint(alice, 10 ether, true);
        _buy(1 ether);
        uint256 minerFee = 1 ether * 300 / 10_000 / 2; // 1.5%

        (, uint256 e) = engine.pending(id);
        assertEq(e, 0, "nothing in the swap block");

        _roll(engine.STREAM_BLOCKS() / 2);
        (, e) = engine.pending(id);
        assertApproxEqRel(e, minerFee / 2, 0.001e18, "half after half the stream");

        _roll(engine.STREAM_BLOCKS());
        (, e) = engine.pending(id);
        assertApproxEqAbs(e, minerFee, TOL, "all after the full stream");

        uint256 before = alice.balance;
        (, uint256 claimedEth) = _claim(alice, id);
        assertEq(alice.balance - before, claimedEth);
        assertApproxEqAbs(claimedEth, minerFee, TOL);
    }

    function test_ethFee_fromSells_alsoReachesMiners() public {
        (uint256 id,) = _mint(alice, 10 ether, true);
        _sell(1_000_000e18);
        _roll(engine.STREAM_BLOCKS() + 1);
        (, uint256 e) = engine.pending(id);
        assertGt(e, 0);
        assertApproxEqAbs(e, engine.totalEthReceived(), TOL);
    }

    function test_jitLiquidity_getsAlmostNothing() public {
        (uint256 a,) = _mint(alice, 1 ether, true);
        _roll(10);

        // Bob adds 9x liquidity right before a big swap and leaves one block later.
        (uint256 b, uint128 lb) = _mint(bob, 9 ether, true);
        _buy(1 ether);
        uint256 minerFee = 1 ether * 300 / 10_000 / 2;
        _roll(1);
        _decrease(bob, b, lb);
        (, uint256 bobEth) = _claim(bob, b);

        assertLt(bobEth, minerFee / 5000, "JIT gets ~1/7200 of its share");

        _roll(engine.STREAM_BLOCKS() + 1);
        (, uint256 aliceEth) = engine.pending(a);
        assertApproxEqAbs(aliceEth + bobEth, minerFee, TOL, "the rest goes to the real miner");
    }

    function test_ethStream_pausedWhileNoMiners() public {
        _buy(0.001 ether); // fee arrives while nobody mines
        uint256 minerFee = engine.totalEthReceived();
        assertGt(minerFee, 0);

        _roll(3 * engine.STREAM_BLOCKS());
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(engine.STREAM_BLOCKS() + 1);
        (, uint256 e) = engine.pending(id);
        assertApproxEqAbs(e, minerFee, TOL, "first miner receives the waiting ETH");
    }

    // ------------------------------------------------------------------
    // Position lifecycle
    // ------------------------------------------------------------------

    /// A transfer unsubscribes the position (PositionManager rule). What was earned stays with the seller;
    /// the buyer starts from zero and must subscribe again to mine.
    function test_transfer_sellerKeepsEarnedRewards() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(100);

        vm.prank(alice);
        IERC721(address(posm)).transferFrom(alice, carol, id);
        assertEq(engine.totalLiquidity(), 0, "transfer stops mining");

        (uint128 owedPrime,) = engine.owed(alice);
        assertApproxEqAbs(owedPrime, 100 * REWARD, TOL);

        (uint256 b,) = _claim(carol, id);
        assertEq(b, 0, "buyer gets nothing earned before the transfer");

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        (uint256 got,) = engine.claimOwed();
        assertApproxEqAbs(got, 100 * REWARD, TOL);
        assertEq(token.balanceOf(alice) - balBefore, got);

        // buyer mines from now on
        _subscribe(carol, id);
        _roll(10);
        (b,) = _claim(carol, id);
        assertApproxEqAbs(b, 10 * REWARD, TOL);
    }

    /// Reviewer finding M-2: unsubscribe then burn must not lose rewards.
    function test_unsubscribeThenBurn_rewardsNotLost() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(100);
        _unsubscribe(alice, id);
        _burn(alice, id);
        vm.prank(alice);
        (uint256 b,) = engine.claimOwed();
        assertApproxEqAbs(b, 100 * REWARD, TOL);
    }

    function test_claimTo_otherRecipient() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(10);
        vm.prank(alice);
        (uint256 b,) = engine.claimTo(id, carol);
        assertEq(token.balanceOf(carol), b);
        assertApproxEqAbs(b, 10 * REWARD, TOL);
    }

    function test_claim_notOwner() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        vm.prank(bob);
        vm.expectRevert(MiningEngine.NotOwner.selector);
        engine.claim(id);
    }

    function test_unsubscribe_stopsMining_keepsRewards() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(100);
        _unsubscribe(alice, id);
        assertEq(engine.totalLiquidity(), 0);

        _roll(100);
        (uint128 b,) = engine.owed(alice);
        assertApproxEqAbs(b, 100 * REWARD, TOL, "earned rewards kept, no more accrual");
        vm.prank(alice);
        (uint256 claimed,) = engine.claimOwed();
        assertApproxEqAbs(claimed, 100 * REWARD, TOL);
    }

    function test_resubscribe_afterUnsubscribe() public {
        (uint256 id, uint128 l) = _mint(alice, 1 ether, true);
        _roll(10);
        _unsubscribe(alice, id);
        _roll(10);
        _subscribe(alice, id);
        assertEq(engine.totalLiquidity(), l);
        _roll(10);
        (uint256 b,) = engine.pending(id);
        assertApproxEqAbs(b, 10 * REWARD, TOL, "current subscription");
        (uint128 o,) = engine.owed(alice);
        assertApproxEqAbs(o, 10 * REWARD, TOL, "first subscription");
    }

    function test_increaseAndDecrease_updateMiningPower() public {
        (uint256 a, uint128 la) = _mint(alice, 1 ether, true);
        (uint256 b, uint128 lb) = _mint(bob, 1 ether, true);

        _increase(alice, a, la, 2 ether); // alice doubles
        (uint128 newLa,,,,,) = engine.miners(a);
        assertEq(newLa, 2 * uint256(la));
        assertEq(engine.totalLiquidity(), 2 * uint256(la) + lb);

        _decrease(bob, b, lb / 2);
        (uint128 newLb,,,,,) = engine.miners(b);
        assertEq(newLb, lb - lb / 2);
        assertEq(engine.totalLiquidity(), 2 * uint256(la) + lb - lb / 2);
    }

    function test_withdrawAllLiquidity_whileSubscribed() public {
        (uint256 id, uint128 l) = _mint(alice, 1 ether, true);
        _roll(50);
        uint256 ethBefore = alice.balance;
        _decrease(alice, id, l);
        assertGt(alice.balance, ethBefore, "liquidity returned");
        assertEq(engine.totalLiquidity(), 0);
        (uint256 b,) = _claim(alice, id);
        assertApproxEqAbs(b, 50 * REWARD, TOL);
    }

    function test_burn_movesRewardsToOwner() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _roll(50);
        _burn(alice, id);
        assertEq(engine.totalLiquidity(), 0);
        (uint128 o,) = engine.owed(alice);
        assertApproxEqAbs(o, 50 * REWARD, TOL);

        vm.prank(alice);
        (uint256 b,) = engine.claimOwed();
        assertApproxEqAbs(b, 50 * REWARD, TOL);
        (o,) = engine.owed(alice);
        assertEq(o, 0);
    }

    function test_claimMany() public {
        (uint256 a,) = _mint(alice, 1 ether, true);
        (uint256 b,) = _mint(alice, 1 ether, true);
        _roll(10);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(alice);
        (uint256 total,) = engine.claimMany(ids);
        assertApproxEqAbs(total, 10 * REWARD, TOL);
    }

    // ------------------------------------------------------------------
    // Eligibility
    // ------------------------------------------------------------------

    function test_concentratedPosition_cannotSubscribe() public {
        int24 tick = TickMath.getTickAtSqrtPrice(_currentSqrtPrice());
        int24 lower = (tick / 60) * 60 - 6000;
        (uint256 id,) = _mintRange(alice, 1 ether, lower, lower + 12_000, false);
        vm.prank(alice);
        vm.expectRevert();
        posm.subscribe(id, address(engine), "");
    }

    function test_otherPool_cannotSubscribe() public {
        PoolKey memory original = key;
        uint160 price = _currentSqrtPrice();
        key = PoolKey(original.currency0, original.currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, price);
        (uint256 id,) = _mint(alice, 1 ether, false);
        key = original;

        vm.prank(alice);
        vm.expectRevert();
        posm.subscribe(id, address(engine), "");
    }

    function test_reservePosition_cannotBeSubscribedByOthers() public {
        uint256 id = reserve.positions(0);
        vm.prank(carol);
        vm.expectRevert();
        posm.subscribe(id, address(engine), "");
    }

    function test_onlyPositionManagerCallbacks() public {
        vm.expectRevert(MiningEngine.OnlyPositionManager.selector);
        engine.notifyUnsubscribe(1);
    }

    function test_sync_isNoopForHealthyPositions() public {
        (uint256 id, uint128 l) = _mint(alice, 1 ether, true);
        engine.sync(id);
        assertEq(engine.totalLiquidity(), l);
    }
}

/// @notice PositionManager with a tiny unsubscribe gas limit: the notification runs out of gas,
///         `sync` must repair the accounting.
contract MiningEngineOutOfGasUnsubscribeTest is PrimeHashFixture {
    function setUp() public override {
        super.setUp();
    }

    /// Worst case: cold storage, PRIME and ETH owed both written for the first time, a halving crossed.
    function test_unsubscribeGas_fitsMainnetLimit() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        _buy(0.1 ether);
        vm.roll(engine.startBlock() + Emission.HALVING_INTERVAL + 10);
        vm.cool(address(engine));
        vm.prank(address(posm));
        uint256 g = gasleft();
        engine.notifyUnsubscribe(id);
        uint256 used = g - gasleft();
        emit log_named_uint("notifyUnsubscribe gas", used);
        assertLt(used, 100_000, "well below mainnet PositionManager's 150,000 limit");
        assertEq(engine.totalLiquidity(), 0);
    }

    function test_sync_fixesStaleLiquidity() public {
        (uint256 id, uint128 l) = _mint(alice, 1 ether, true);
        assertEq(engine.totalLiquidity(), l);

        // Simulate an unsubscribe whose notification failed: PositionManager forgets the subscriber,
        // the engine never heard about it.
        vm.mockCall(address(posm), abi.encodeWithSignature("subscriber(uint256)", id), abi.encode(address(0)));
        engine.sync(id);
        assertEq(engine.totalLiquidity(), 0);
        vm.clearMockedCalls();
    }
}
