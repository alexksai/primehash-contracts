// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PrimeHashFixture} from "./utils/PrimeHashFixture.sol";
import {GenesisReserve} from "../src/GenesisReserve.sol";
import {PrimeHashHook} from "../src/PrimeHashHook.sol";

contract GenesisReserveTest is PrimeHashFixture {
    function test_launchOnlyOnce() public {
        uint160 price = _currentSqrtPrice();
        vm.expectRevert(GenesisReserve.AlreadyLaunched.selector);
        reserve.launch{value: 1}(key, price, 1);
    }

    function test_launch_startingPrice() public view {
        // 1 ETH ~ 1,050,000 PRIME
        uint256 p = _currentSqrtPrice();
        uint256 price = p * p / (1 << 192);
        assertApproxEqRel(price, 1_050_000, 0.001e18);
    }

    function test_addLiquidity_onlyTreasury() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(GenesisReserve.OnlyTreasury.selector);
        reserve.addLiquidity{value: 1 ether}(1e18, 1e24, 0, type(uint160).max, block.timestamp);
    }

    function test_addLiquidity_usesReservePrime() public {
        uint160 p = _currentSqrtPrice();
        uint256 eth = 0.01 ether;
        uint128 liq = _liquidityFor(p, eth, 10_500e18) * 99 / 100;
        uint256 reserveBefore = reserve.reserveBalance();

        vm.deal(treasury, eth);
        vm.prank(treasury);
        reserve.addLiquidity{value: eth}(liq, 11_000e18, p - 1, p + 1, block.timestamp);

        uint256 used = reserveBefore - reserve.reserveBalance();
        assertApproxEqRel(used, 10_500e18, 0.02e18);
        assertEq(reserve.positionCount(), 2);
        assertEq(IERC721(address(posm)).ownerOf(reserve.positions(1)), address(reserve));
        assertEq(engine.totalLiquidity(), 0, "protocol positions never mine");
        assertEq(_currentSqrtPrice(), p, "adding liquidity does not move the price");
    }

    function test_addLiquidity_revertsIfPriceManipulated() public {
        uint160 p = _currentSqrtPrice();
        _buy(0.005 ether); // someone pumps the price right before
        uint160 pumped = _currentSqrtPrice();
        vm.deal(treasury, 0.01 ether);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(GenesisReserve.PriceOutOfRange.selector, pumped));
        reserve.addLiquidity{value: 0.01 ether}(1e18, 11_000e18, p * 99 / 100, p * 101 / 100, block.timestamp);
    }

    function test_collectFees_goToTreasury() public {
        _buy(0.005 ether);
        _sell(5_000e18);
        uint256 ethBefore = treasury.balance;
        uint256 id = reserve.positions(0);
        vm.prank(treasury);
        reserve.collectFees(id);
        assertGt(treasury.balance, ethBefore, "0.30% LP fees in ETH");
        assertGt(token.balanceOf(treasury), 0, "0.30% LP fees in PRIME");
    }

    function test_collectFees_doesNotTouchLiquidity() public {
        uint256 id = reserve.positions(0);
        uint128 before = posm.getPositionLiquidity(id);
        vm.prank(treasury);
        reserve.collectFees(id);
        assertEq(posm.getPositionLiquidity(id), before);
    }

    function test_hookTreasuryFlow_endToEnd() public {
        _buy(0.01 ether);
        uint256 fee = 0.01 ether * 300 / 10_000;
        assertEq(hook.treasuryBalance(), fee - fee / 2);
        uint256 before = treasury.balance; // includes unused launch ETH refunded by the reserve
        hook.withdrawTreasury();
        assertEq(treasury.balance - before, fee - fee / 2);
        assertEq(engine.totalEthReceived(), fee / 2);
    }

    function test_nobodyElseCanInitializeThePool() public {
        // The hook already has its pool; and a new pool with this hook is rejected.
        assertTrue(hook.poolInitialized());
        uint160 price = _currentSqrtPrice();
        vm.expectRevert();
        manager.initialize(key, price);
    }
}
