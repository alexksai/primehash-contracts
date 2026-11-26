// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {PrimeHashHook} from "../src/PrimeHashHook.sol";
import {IMiningEngine} from "../src/interfaces/IMiningEngine.sol";

contract MockEngine is IMiningEngine {
    uint256 public received;
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function notifyEth() external payable {
        require(!broken, "broken");
        received += msg.value;
    }
}

contract PrimeHashHookTest is Test, Deployers {
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    int24 constant MIN_TICK = -887220; // full range for tick spacing 60
    int24 constant MAX_TICK = 887220;
    uint256 constant BPS = 10_000;
    uint256 constant FEE_BPS = 300;

    PrimeHashHook hook;
    MockEngine engine;
    MockERC20 primeToken;
    address treasury = makeAddr("treasury");

    PoolKey hookedKey; // ETH/PRIME with PrimeHashHook
    PoolKey plainKey; // identical pool, no hook, used as reference

    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        vm.roll(1_000);
        deployFreshManagerAndRouters();

        primeToken = new MockERC20("PrimeHash", "PRIME", 18);
        primeToken.mint(address(this), 1e30);
        primeToken.approve(address(swapRouter), type(uint256).max);
        primeToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        engine = new MockEngine();
        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo(
            "PrimeHashHook.sol:PrimeHashHook",
            abi.encode(manager, engine, treasury, address(primeToken), address(this)),
            hookAddr
        );
        hook = PrimeHashHook(payable(hookAddr));

        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency blk = Currency.wrap(address(primeToken));
        hookedKey = PoolKey(eth, blk, 3000, 60, IHooks(hookAddr));
        plainKey = PoolKey(eth, blk, 3000, 60, IHooks(address(0)));

        // Price: 1 ETH = 1,000,000 PRIME  ->  sqrtPrice = sqrt(1e6) * 2^96
        uint160 sqrtPrice = uint160(1000 * (uint256(1) << 96));
        manager.initialize(hookedKey, sqrtPrice);
        manager.initialize(plainKey, sqrtPrice);

        vm.deal(address(this), 1_000 ether);
        _addFullRange(hookedKey, 10 ether);
        _addFullRange(plainKey, 10 ether);
    }

    // ------------------------------------------------------------------
    // The 4 swap cases, compared against the identical pool without hook
    // ------------------------------------------------------------------

    /// ETH -> PRIME, exact input: swapper pays X ETH, X*3% goes to the hook, X*97% is swapped.
    function test_ethToPrime_exactInput() public {
        _check_ethToPrime_exactInput(0.1 ether);
    }

    /// PRIME -> ETH, exact input: the ETH output is reduced by 3%.
    function test_primeToEth_exactInput() public {
        _check_primeToEth_exactInput(100_000e18);
    }

    /// PRIME -> ETH, exact output: swapper receives exactly Y ETH, pool outputs Y + fee.
    function test_primeToEth_exactOutput() public {
        _check_primeToEth_exactOutput(0.1 ether);
    }

    /// ETH -> PRIME, exact output: swapper receives exactly N PRIME and pays ETH + fee.
    function test_ethToPrime_exactOutput() public {
        _check_ethToPrime_exactOutput(100_000e18);
    }

    function testFuzz_ethToPrime_exactInput(uint256 amount) public {
        _check_ethToPrime_exactInput(bound(amount, 1e9, 5 ether));
    }

    function testFuzz_primeToEth_exactInput(uint256 amount) public {
        _check_primeToEth_exactInput(bound(amount, 1e15, 5_000_000e18));
    }

    function testFuzz_primeToEth_exactOutput(uint256 amount) public {
        _check_primeToEth_exactOutput(bound(amount, 1e9, 3 ether));
    }

    function testFuzz_ethToPrime_exactOutput(uint256 amount) public {
        _check_ethToPrime_exactOutput(bound(amount, 1e15, 3_000_000e18));
    }

    // ------------------------------------------------------------------
    // Fee split, treasury, safety
    // ------------------------------------------------------------------

    function test_feeSplit_halfMinersHalfTreasury() public {
        _swap(hookedKey, true, -1 ether);
        uint256 fee = 1 ether * FEE_BPS / BPS; // 0.03 ETH
        assertEq(engine.received() + hook.pendingMinerEth(), fee / 2, "miners get 1.5%");
        assertEq(hook.treasuryBalance(), fee - fee / 2, "treasury gets 1.5%");
        assertEq(address(hook).balance, hook.treasuryBalance() + hook.pendingMinerEth(), "hook only holds treasury + not-yet-forwarded miner ETH");
    }

    function test_withdrawTreasury_anyoneCanTrigger_fundsGoToTreasury() public {
        _swap(hookedKey, true, -1 ether);
        uint256 bal = hook.treasuryBalance();

        vm.prank(makeAddr("random"));
        hook.withdrawTreasury();

        assertEq(treasury.balance, bal);
        assertEq(hook.treasuryBalance(), 0);
        assertEq(address(hook).balance, hook.pendingMinerEth());
    }

    function test_brokenEngine_doesNotBlockSwaps_andIsRetried() public {
        engine.setBroken(true);
        _swap(hookedKey, true, -1 ether);
        uint256 minerFee = (1 ether * FEE_BPS / BPS) / 2;
        assertEq(hook.pendingMinerEth(), minerFee, "kept for later");
        assertEq(engine.received(), 0);

        engine.setBroken(false);
        hook.flushMinerEth();
        assertEq(hook.pendingMinerEth(), 0);
        assertEq(engine.received(), minerFee);
    }

    function test_liquidityCanAlwaysBeRemoved() public {
        _swap(hookedKey, true, -1 ether);
        _swap(hookedKey, false, -100_000e18);
        uint256 ethBefore = address(this).balance;
        modifyLiquidityRouter.modifyLiquidity(
            hookedKey, ModifyLiquidityParams(MIN_TICK, MAX_TICK, -int256(_liquidityFor10Eth()), 0), ZERO_BYTES
        );
        assertGt(address(this).balance, ethBefore);
    }

    function test_secondPoolCannotUseHook() public {
        PoolKey memory other = PoolKey(CurrencyLibrary.ADDRESS_ZERO, hookedKey.currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PrimeHashHook.PoolAlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_onlyInitializerCanCreatePool() public {
        // Fresh hook that has not been used yet, initializer = this contract.
        address hookAddr = address(FLAGS | (uint160(0x5555) << 144));
        deployCodeTo(
            "PrimeHashHook.sol:PrimeHashHook",
            abi.encode(manager, engine, treasury, address(primeToken), address(this)),
            hookAddr
        );
        PoolKey memory key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, hookedKey.currency1, 3000, 60, IHooks(hookAddr));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);

        manager.initialize(key, SQRT_PRICE_1_1); // initializer succeeds
        assertTrue(PrimeHashHook(payable(hookAddr)).poolInitialized());
    }

    function test_hookCallbacksOnlyFromPoolManager() public {
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(PrimeHashHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), hookedKey, p, ZERO_BYTES);
    }

    // ------------------------------------------------------------------
    // Case checks
    // ------------------------------------------------------------------

    function _check_ethToPrime_exactInput(uint256 amountIn) internal {
        uint256 fee = amountIn * FEE_BPS / BPS;
        BalanceDelta ref = _swap(plainKey, true, -int256(amountIn - fee));
        (BalanceDelta d, uint256 collected) = _swapHooked(true, -int256(amountIn));

        assertEq(-int256(d.amount0()), int256(amountIn), "swapper pays exactly X ETH");
        assertEq(d.amount1(), ref.amount1(), "PRIME out == plain swap of X - fee");
        assertEq(collected, fee, "fee = 3% of X");
    }

    function _check_primeToEth_exactInput(uint256 primeIn) internal {
        BalanceDelta ref = _swap(plainKey, false, -int256(primeIn));
        (BalanceDelta d, uint256 collected) = _swapHooked(false, -int256(primeIn));

        uint256 gross = uint256(int256(ref.amount0()));
        uint256 fee = gross * FEE_BPS / BPS;
        assertEq(d.amount1(), ref.amount1(), "same PRIME in");
        assertEq(uint256(int256(d.amount0())), gross - fee, "ETH out reduced by 3%");
        assertEq(collected, fee);
    }

    function _check_primeToEth_exactOutput(uint256 ethOut) internal {
        uint256 fee = ethOut * FEE_BPS / (BPS - FEE_BPS);
        BalanceDelta ref = _swap(plainKey, false, int256(ethOut + fee));
        (BalanceDelta d, uint256 collected) = _swapHooked(false, int256(ethOut));

        assertEq(uint256(int256(d.amount0())), ethOut, "swapper receives exactly Y ETH");
        assertEq(d.amount1(), ref.amount1(), "PRIME in == plain swap for Y + fee");
        assertEq(collected, fee);
        _assertFeeIsThreePercentOf(fee, ethOut + fee);
    }

    function _check_ethToPrime_exactOutput(uint256 primeOut) internal {
        BalanceDelta ref = _swap(plainKey, true, int256(primeOut));
        (BalanceDelta d, uint256 collected) = _swapHooked(true, int256(primeOut));

        uint256 ethForPool = uint256(-int256(ref.amount0()));
        uint256 fee = ethForPool * FEE_BPS / (BPS - FEE_BPS);
        assertEq(d.amount1(), ref.amount1(), "swapper receives exactly N PRIME");
        assertEq(uint256(-int256(d.amount0())), ethForPool + fee, "pays pool price + fee");
        assertEq(collected, fee);
        _assertFeeIsThreePercentOf(fee, ethForPool + fee);
    }

    /// fee / total must be 3% (within 1 wei of rounding).
    function _assertFeeIsThreePercentOf(uint256 fee, uint256 total) internal pure {
        uint256 expected = total * FEE_BPS / BPS;
        assertApproxEqAbs(fee, expected, 1, "fee is 3% of the gross ETH amount");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _swapHooked(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta d, uint256 collected) {
        uint256 before = engine.received() + hook.treasuryBalance() + hook.pendingMinerEth();
        d = _swap(hookedKey, zeroForOne, amountSpecified);
        collected = engine.received() + hook.treasuryBalance() + hook.pendingMinerEth() - before;
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        // Send plenty of ETH; PoolSwapTest refunds nothing, so only send when ETH is paid.
        uint256 value = zeroForOne ? 100 ether : 0;
        return swapRouter.swap{value: value}(key, p, settings, ZERO_BYTES);
    }

    function _liquidityFor10Eth() internal pure returns (uint256) {
        // L = amount0 * sqrtP for full range ~ 10 ether * 1000
        return 10 ether * 1000 * 99 / 100;
    }

    function _addFullRange(PoolKey memory key, uint256 ethAmount) internal {
        modifyLiquidityRouter.modifyLiquidity{value: ethAmount * 2}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(ethAmount * 1000), 0), ZERO_BYTES
        );
    }


    function test_minerEth_forwardedAtMostOncePerInterval() public {
        _swap(hookedKey, true, -1 ether); // first swap: interval elapsed since block 0, forwarded
        uint256 first = engine.received();
        assertGt(first, 0);
        _swap(hookedKey, true, -1 ether); // same block: kept in the hook, no engine call
        assertEq(engine.received(), first);
        assertGt(hook.pendingMinerEth(), 0);
        vm.roll(block.number + hook.PUSH_INTERVAL());
        _swap(hookedKey, true, -1 ether); // interval passed: everything pending is forwarded
        assertEq(hook.pendingMinerEth(), 0);
        assertGt(engine.received(), first * 2);
    }

    function test_flushMinerEth_anytime() public {
        _swap(hookedKey, true, -1 ether);
        _swap(hookedKey, true, -1 ether);
        uint256 pending = hook.pendingMinerEth();
        uint256 before = engine.received();
        hook.flushMinerEth();
        assertEq(engine.received() - before, pending);
        assertEq(hook.pendingMinerEth(), 0);
    }
}
