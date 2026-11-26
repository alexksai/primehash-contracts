// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {PositionManager} from "v4-periphery/PositionManager.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

import {PrimeToken} from "../../src/PrimeToken.sol";
import {MiningEngine} from "../../src/MiningEngine.sol";
import {PrimeHashHook} from "../../src/PrimeHashHook.sol";
import {GenesisReserve} from "../../src/GenesisReserve.sol";

/// @notice Deploys the full PrimeHash system on top of real Uniswap v4 PoolManager + PositionManager,
///         in the same order as the production deploy script.
abstract contract PrimeHashFixture is Test, Deployers, DeployPermit2 {
    using StateLibrary for *;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    /// Launch: 21,000 PRIME paired with 0.02 ETH  ->  1 ETH = 1,050,000 PRIME
    uint256 constant LAUNCH_ETH = 0.02 ether;
    uint256 constant LAUNCH_PRIME = 21_000e18;

    IAllowanceTransfer permit2;
    IPositionManager posm;
    GenesisReserve reserve;
    MiningEngine engine;
    PrimeToken token;
    PrimeHashHook hook;
    // `key` (the PrimeHash pool) is inherited from Deployers

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    PoolSwapTest.TestSettings swapSettings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public virtual {
        vm.roll(1_000);
        deployFreshManagerAndRouters();
        permit2 = IAllowanceTransfer(deployPermit2());
        posm = IPositionManager(
            address(
                new PositionManager(manager, permit2, 150_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
            )
        );

        // 1. reserve  2. engine  2b. token  3. hook  4. engine.initialize  5. reserve.launch
        reserve = new GenesisReserve(manager, posm, permit2, treasury);
        engine = new MiningEngine(posm);
        token = new PrimeToken(address(engine), address(reserve));

        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo(
            "PrimeHashHook.sol:PrimeHashHook",
            abi.encode(manager, engine, treasury, address(token), address(reserve)),
            hookAddr
        );
        hook = PrimeHashHook(payable(hookAddr));

        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(hookAddr));
        engine.initialize(key);

        uint160 sqrtPrice = _sqrtPriceForAmounts(LAUNCH_ETH, LAUNCH_PRIME);
        uint128 liq = _liquidityFor(sqrtPrice, LAUNCH_ETH, LAUNCH_PRIME) * 999 / 1000;
        vm.deal(address(this), 1_000_000 ether);
        reserve.launch{value: LAUNCH_ETH}(key, sqrtPrice, liq);

        token.approve(address(swapRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _sqrtPriceForAmounts(uint256 ethAmount, uint256 primeAmount) internal pure returns (uint160) {
        // price = token1 / token0 ; sqrtPriceX96 = sqrt(price * 2^192)
        return uint160(Math.sqrt(Math.mulDiv(primeAmount, 1 << 192, ethAmount)));
    }

    function _liquidityFor(uint160 sqrtPrice, uint256 ethAmount, uint256 primeAmount) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(MIN_TICK), TickMath.getSqrtPriceAtTick(MAX_TICK), ethAmount, primeAmount
        );
    }

    /// @dev `block.number` can be cached under via-ir after vm.roll, so read it through the cheatcode.
    function _roll(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
    }

    function _currentSqrtPrice() internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(key.toId());
    }

    /// @dev Gives `user` enough ETH + PRIME, mints a full-range position with ~`ethAmount` ETH and, if `subscribe`,
    ///      subscribes it to the engine in the same transaction (multicall), like the website will do.
    function _mint(address user, uint256 ethAmount, bool subscribe) internal returns (uint256 tokenId, uint128 liq) {
        return _mintRange(user, ethAmount, MIN_TICK, MAX_TICK, subscribe);
    }

    function _mintRange(address user, uint256 ethAmount, int24 lower, int24 upper, bool subscribe)
        internal
        returns (uint256 tokenId, uint128 liq)
    {
        uint160 p = _currentSqrtPrice();
        uint256 primeAmount = Math.mulDiv(ethAmount, uint256(p) * uint256(p), 1 << 192) * 2 + 1e18;
        liq = LiquidityAmounts.getLiquidityForAmounts(
            p, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), ethAmount, primeAmount
        ) * 99 / 100;

        vm.deal(user, user.balance + ethAmount * 2);
        deal(address(token), user, token.balanceOf(user) + primeAmount);
        tokenId = posm.nextTokenId();

        vm.startPrank(user);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(posm), type(uint160).max, type(uint48).max);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, upper, uint256(liq), uint128(ethAmount * 2), uint128(primeAmount), user, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, user);

        bytes[] memory calls = new bytes[](subscribe ? 2 : 1);
        calls[0] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp));
        if (subscribe) calls[1] = abi.encodeCall(posm.subscribe, (tokenId, address(engine), ""));
        posm.multicall{value: ethAmount * 2}(calls);
        vm.stopPrank();
    }

    function _subscribe(address user, uint256 tokenId) internal {
        vm.prank(user);
        posm.subscribe(tokenId, address(engine), "");
    }

    function _unsubscribe(address user, uint256 tokenId) internal {
        vm.prank(user);
        posm.unsubscribe(tokenId);
    }

    function _decrease(address user, uint256 tokenId, uint256 liquidity) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, user);
        vm.prank(user);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _increase(address user, uint256 tokenId, uint256 liquidity, uint256 ethMax) internal {
        uint160 p = _currentSqrtPrice();
        uint256 primeAmount = Math.mulDiv(ethMax, uint256(p) * uint256(p), 1 << 192) * 2 + 1e18;
        vm.deal(user, user.balance + ethMax);
        deal(address(token), user, token.balanceOf(user) + primeAmount);
        vm.startPrank(user);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        // CLOSE_CURRENCY (not SETTLE_PAIR): accrued LP fees may exceed what the increase needs, making a delta positive.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(tokenId, liquidity, uint128(ethMax), uint128(primeAmount), "");
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        params[3] = abi.encode(key.currency0, user);
        vm.prank(user);
        posm.modifyLiquidities{value: ethMax}(abi.encode(actions, params), block.timestamp);
    }

    function _burn(address user, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, user);
        vm.prank(user);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _buy(uint256 ethIn) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethIn}(
            key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), swapSettings, ""
        );
    }

    function _sell(uint256 primeIn) internal returns (BalanceDelta) {
        deal(address(token), address(this), token.balanceOf(address(this)) + primeIn);
        return swapRouter.swap(key, SwapParams(false, -int256(primeIn), TickMath.MAX_SQRT_PRICE - 1), swapSettings, "");
    }

    function _claim(address user, uint256 tokenId) internal returns (uint256 b, uint256 e) {
        vm.prank(user);
        return engine.claim(tokenId);
    }
}
