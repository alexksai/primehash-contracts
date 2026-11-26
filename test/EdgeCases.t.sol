// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PrimeToken} from "../src/PrimeToken.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PrimeHashFixture} from "./utils/PrimeHashFixture.sol";
import {PrimeHashHook} from "../src/PrimeHashHook.sol";
import {GenesisReserve} from "../src/GenesisReserve.sol";
import {MiningEngine} from "../src/MiningEngine.sol";
import {IMiningEngine} from "../src/interfaces/IMiningEngine.sol";

contract EdgeCasesTest is PrimeHashFixture {
    // ---------------- hook ----------------

    function test_dustSwaps_noFee_stillWork() public {
        uint256 before = engine.totalEthReceived() + hook.treasuryBalance();
        _buy(33); // 3% of 33 wei rounds to 0
        _sell(1); // 1 wei of PRIME
        assertEq(engine.totalEthReceived() + hook.treasuryBalance(), before, "no fee on dust");
    }

    function test_unusedCallbacksRevert() public {
        ModifyLiquidityParams memory p;
        BalanceDelta z;
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), key, 0, 0);
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(0), key, p, "");
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(0), key, p, z, z, "");
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), key, p, "");
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(0), key, p, z, z, "");
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.beforeDonate(address(0), key, 0, 0, "");
        vm.expectRevert(PrimeHashHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), key, 0, 0, "");
    }

    function test_hookRejectsPlainEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    function test_hookRejectsZeroTreasury() public {
        address hookAddr = address(FLAGS | (uint160(0x7777) << 144));
        vm.expectRevert(PrimeHashHook.ZeroAddress.selector);
        deployCodeTo(
            "PrimeHashHook.sol:PrimeHashHook",
            abi.encode(manager, engine, address(0), address(token), address(reserve)),
            hookAddr
        );
    }

    function test_withdrawTreasury_revertsIfTreasuryRejectsEth() public {
        // treasury that cannot receive ETH
        address hookAddr = address(FLAGS | (uint160(0x8888) << 144));
        address badTreasury = address(new Rejector());
        deployCodeTo(
            "PrimeHashHook.sol:PrimeHashHook",
            abi.encode(manager, engine, badTreasury, address(token), address(reserve)),
            hookAddr
        );
        vm.expectRevert(PrimeHashHook.TransferFailed.selector);
        PrimeHashHook(payable(hookAddr)).withdrawTreasury();
    }

    /// Reviewer finding M-1: a swap that would only partly fill (price limit hit) must revert, not overcharge.
    function test_partialFill_exactInEth_reverts() public {
        uint160 p = _currentSqrtPrice();
        vm.expectRevert(); // PartialFillNotSupported, wrapped by PoolManager
        swapRouter.swap{value: 10 ether}(key, SwapParams(true, -10 ether, p * 999 / 1000), swapSettings, "");
    }

    function test_partialFill_exactOutEth_reverts() public {
        uint160 p = _currentSqrtPrice();
        deal(address(token), address(this), 1e30);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams(false, 5 ether, p * 1001 / 1000), swapSettings, "");
    }

    function test_partialFill_onUnspecifiedEth_isFine() public {
        // PRIME -> ETH exact input with a tight limit: fee is computed on the ETH actually received, so it's allowed.
        uint160 p = _currentSqrtPrice();
        deal(address(token), address(this), 1e30);
        uint256 before = engine.totalEthReceived() + hook.treasuryBalance();
        BalanceDelta d = swapRouter.swap(key, SwapParams(false, -1_000_000e18, p * 1001 / 1000), swapSettings, "");
        uint256 fee = engine.totalEthReceived() + hook.treasuryBalance() - before;
        uint256 gross = uint256(int256(d.amount0())) + fee;
        assertApproxEqAbs(fee, gross * 300 / 10_000, 1);
    }

    function test_fullFillWithExplicitLimit_works() public {
        uint160 p = _currentSqrtPrice();
        // small swap, limit far enough: full fill, no revert
        swapRouter.swap{value: 0.0001 ether}(key, SwapParams(true, -0.0001 ether, p / 2), swapSettings, "");
    }

    // ---------------- reserve ----------------

    function test_launch_onlyDeployer() public {
        GenesisReserve r = new GenesisReserve(manager, posm, permit2, treasury);
        vm.prank(alice);
        vm.expectRevert(GenesisReserve.OnlyDeployer.selector);
        r.launch(key, 1, 1);
    }

    function test_launch_invalidKey() public {
        GenesisReserve r = new GenesisReserve(manager, posm, permit2, treasury);
        PoolKey memory bad = PoolKey(Currency.wrap(address(token)), Currency.wrap(address(1)), 3000, 60, IHooks(address(0)));
        vm.expectRevert(GenesisReserve.InvalidPoolKey.selector);
        r.launch(bad, 1, 1);
        bad = PoolKey(CurrencyLibrary.ADDRESS_ZERO, key.currency1, 3000, 10, key.hooks);
        vm.expectRevert(GenesisReserve.InvalidPoolKey.selector);
        r.launch(bad, 1, 1);
    }

    function test_addLiquidity_beforeLaunch() public {
        GenesisReserve r = new GenesisReserve(manager, posm, permit2, treasury);
        vm.prank(treasury);
        vm.expectRevert(GenesisReserve.NotLaunched.selector);
        r.addLiquidity(1, 1, 0, type(uint160).max, block.timestamp);
    }

    function test_addLiquidity_tooMuchPrime() public {
        vm.prank(treasury);
        vm.expectRevert(GenesisReserve.TooMuchPrime.selector);
        reserve.addLiquidity(1, uint256(type(uint128).max) + 1, 0, type(uint160).max, block.timestamp);
    }

    function test_collectFees_onlyTreasury() public {
        vm.prank(alice);
        vm.expectRevert(GenesisReserve.OnlyTreasury.selector);
        reserve.collectFees(1);
    }

    function test_reserve_rejectsZeroTreasury() public {
        vm.expectRevert(bytes("treasury = 0"));
        new GenesisReserve(manager, posm, permit2, address(0));
    }

    function test_reserveBalance_beforeLaunch_isZero() public {
        GenesisReserve r = new GenesisReserve(manager, posm, permit2, treasury);
        assertEq(r.reserveBalance(), 0);
    }

    // ---------------- engine ----------------

    function test_notifyEth_zeroIsNoop() public {
        engine.notifyEth{value: 0}();
        assertEq(engine.totalEthReceived(), 0);
    }

    function test_anyoneCanDonateEthToMiners() public {
        (uint256 id,) = _mint(alice, 1 ether, true);
        engine.notifyEth{value: 1 ether}();
        _roll(engine.STREAM_BLOCKS() + 1);
        (, uint256 e) = engine.pending(id);
        assertApproxEqAbs(e, 1 ether, 1e9);
    }

    function test_initialize_invalidKey() public {
        MiningEngine e = new MiningEngine(posm);
        PoolKey memory bad = PoolKey(CurrencyLibrary.ADDRESS_ZERO, key.currency1, 3000, 60, key.hooks); // wrong token
        vm.expectRevert(MiningEngine.InvalidPoolKey.selector);
        e.initialize(bad);
        // a token whose minter is another engine
        PrimeToken other = new PrimeToken(address(e), address(this));
        bad = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(other)), 3000, 60, IHooks(address(0)));
        vm.expectRevert(MiningEngine.InvalidPoolKey.selector);
        e.initialize(bad);
        bad = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(other)), 3000, 60, key.hooks);
        MiningEngine e2 = new MiningEngine(posm);
        vm.expectRevert(MiningEngine.InvalidPoolKey.selector);
        e2.initialize(bad); // `other` mints for `e`, not `e2`
    }

    function test_subscribeBeforeInitialize_reverts() public {
        MiningEngine e = new MiningEngine(posm);
        (uint256 id,) = _mint(alice, 1 ether, false);
        vm.prank(alice);
        vm.expectRevert();
        posm.subscribe(id, address(e), "");
    }

    function test_currentReward_beforeInitialize() public {
        MiningEngine e = new MiningEngine(posm);
        (uint256 r, uint256 next) = e.currentReward();
        assertEq(r, 5e18);
        assertEq(next, 0);
        assertEq(e.miningPowerBps(1), 0);
    }

    function test_claimOwed_nothing() public {
        vm.prank(alice);
        (uint256 b, uint256 e) = engine.claimOwed();
        assertEq(b + e, 0);
    }
}

contract Rejector {
    receive() external payable {
        revert();
    }
}
