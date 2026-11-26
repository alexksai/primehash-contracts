// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {PrimeHashDeployer} from "../../script/PrimeHashDeployer.sol";

/// Struct layouts of the contracts actually deployed on mainnet (older v4-periphery than lib/ master,
/// which added `minHopPriceX36`).
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct QuoteExactSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IV4QuoterDeployed {
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Full deployment + real user flows against the live Uniswap v4 contracts on an Ethereum mainnet fork.
///         Skipped unless MAINNET_RPC_URL is set:
///         MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com ~/.foundry/bin/forge test --mc MainnetForkTest -vv
contract MainnetForkTest is Test, PrimeHashDeployer {
    using StateLibrary for *;
    using PoolIdLibrary for PoolKey;

    IUniversalRouter constant ROUTER = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IV4QuoterDeployed constant QUOTER = IV4QuoterDeployed(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    uint8 constant V4_SWAP = 0x10;

    uint256 constant LAUNCH_ETH = 0.02 ether;

    Uniswap u;
    Deployment d;
    address deployer = makeAddr("deployer");
    address treasury = makeAddr("treasury");
    address trader = makeAddr("trader");
    address miner = makeAddr("miner");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        u = _uniswap(1);
        vm.deal(deployer, 1 ether);
        uint256 g = gasleft();
        vm.startPrank(deployer, deployer);
        d = _deploy(u, treasury, LAUNCH_ETH);
        vm.stopPrank();
        console.log("deploy gas (approx, excl. tx overhead):", g - gasleft());
    }

    modifier onlyFork() {
        if (!forked) {
            console.log("MAINNET_RPC_URL not set - skipping fork test");
            return;
        }
        _;
    }

    function test_fork_deployment() public onlyFork {
        assertTrue(d.hook.poolInitialized());
        assertEq(d.token.totalSupply(), 210_000e18);
        assertGe(d.token.balanceOf(address(d.reserve)), 89_000e18);
        assertEq(d.token.balanceOf(deployer), 100_000e18);
        assertEq(IERC721(address(u.positionManager)).ownerOf(d.reserve.positions(0)), address(d.reserve));
        (uint160 p,,,) = u.poolManager.getSlot0(d.key.toId());
        assertEq(p, d.sqrtPriceX96);
        assertEq(uint160(address(d.hook)) & 0x3fff, HOOK_FLAGS);
    }

    function test_fork_quoteAndBuy_viaUniversalRouter() public onlyFork {
        uint128 amountIn = 0.001 ether;
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(QuoteExactSingleParams(d.key, true, amountIn, ""));
        assertGt(quoted, 0, "quoter works with the hook");

        vm.deal(trader, 1 ether);
        uint256 out = _routerBuy(trader, amountIn, uint128(quoted));
        assertEq(out, quoted, "router result == quote");

        uint256 fee = uint256(amountIn) * 300 / 10_000;
        assertEq(d.hook.treasuryBalance(), fee - fee / 2);
        assertEq(d.engine.totalEthReceived(), fee / 2);
    }

    function test_fork_sell_viaUniversalRouter() public onlyFork {
        vm.deal(trader, 1 ether);
        uint256 bought = _routerBuy(trader, 0.002 ether, 0);

        (uint256 quoted,) = QUOTER.quoteExactInputSingle(QuoteExactSingleParams(d.key, false, uint128(bought), ""));
        uint256 ethBefore = trader.balance;

        vm.startPrank(trader);
        d.token.approve(address(u.permit2), type(uint256).max);
        u.permit2.approve(address(d.token), address(ROUTER), type(uint160).max, type(uint48).max);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(d.key, false, uint128(bought), uint128(quoted), ""));
        params[1] = abi.encode(d.key.currency1, bought);
        params[2] = abi.encode(d.key.currency0, quoted);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        ROUTER.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
        vm.stopPrank();

        assertEq(trader.balance - ethBefore, quoted, "received quoted ETH (after 3% hook fee)");
    }

    function test_fork_mineAndClaim() public onlyFork {
        // Miner buys PRIME through the router, then mints a full-range position + subscribes in one tx.
        vm.deal(miner, 1 ether);
        _routerBuy(miner, 0.01 ether, 0);
        uint256 primeBal = d.token.balanceOf(miner);

        (uint160 p,,,) = u.poolManager.getSlot0(d.key.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            p, TickMath.getSqrtPriceAtTick(MIN_TICK), TickMath.getSqrtPriceAtTick(MAX_TICK), 0.5 ether, primeBal
        ) * 99 / 100;
        uint256 tokenId = u.positionManager.nextTokenId();

        vm.startPrank(miner);
        d.token.approve(address(u.permit2), type(uint256).max);
        u.permit2.approve(address(d.token), address(u.positionManager), type(uint160).max, type(uint48).max);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(d.key, MIN_TICK, MAX_TICK, uint256(liq), uint128(0.5 ether), uint128(primeBal), miner, "");
        params[1] = abi.encode(d.key.currency0, d.key.currency1);
        params[2] = abi.encode(d.key.currency0, miner);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp));
        calls[1] = abi.encodeCall(u.positionManager.subscribe, (tokenId, address(d.engine), ""));
        u.positionManager.multicall{value: 0.5 ether}(calls);
        vm.stopPrank();

        assertEq(d.engine.miningPowerBps(tokenId), 10_000);

        vm.deal(trader, 1 ether);
        _routerBuy(trader, 0.01 ether, 0);
        vm.roll(block.number + 7300);

        vm.prank(miner);
        (uint256 b, uint256 e) = d.engine.claim(tokenId);
        console.log("claimed PRIME", b / 1e18);
        console.log("claimed ETH (wei)", e);
        assertApproxEqRel(b, 7300 * 5e18, 0.001e18);
        assertApproxEqAbs(e, d.engine.totalEthReceived(), 1e9);

        // and the miner can leave with their liquidity
        vm.prank(miner);
        u.positionManager.unsubscribe(tokenId);
        assertEq(d.engine.totalLiquidity(), 0);
    }

    function test_fork_zapAndMint_thenSubscribe() public onlyFork {
        address user = makeAddr("zapUser");
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        (uint256 id, uint128 liq) = d.zap.zapAndMint{value: 0.01 ether}(0.005 ether, 1, block.timestamp + 600, address(0));
        u.positionManager.subscribe(id, address(d.engine), "");
        vm.stopPrank();
        assertEq(IERC721(address(u.positionManager)).ownerOf(id), user);
        assertEq(d.engine.totalLiquidity(), liq);
        assertEq(d.engine.miningPowerBps(id), 10_000);
        assertEq(address(d.zap).balance, 0);
        assertEq(d.token.balanceOf(address(d.zap)), 0);
    }

    function _routerBuy(address who, uint128 amountIn, uint128 minOut) internal returns (uint256 out) {
        uint256 before = d.token.balanceOf(who);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(d.key, true, amountIn, minOut, ""));
        params[1] = abi.encode(d.key.currency0, uint256(amountIn));
        params[2] = abi.encode(d.key.currency1, uint256(minOut));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(who);
        ROUTER.execute{value: amountIn}(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
        out = d.token.balanceOf(who) - before;
    }
}
