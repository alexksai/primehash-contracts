// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PrimeHashFixture} from "./utils/PrimeHashFixture.sol";
import {MiningZap} from "../src/MiningZap.sol";

interface IApproved {
    function getApproved(uint256 id) external view returns (address);
}

contract MiningZapTest is PrimeHashFixture {
    using StateLibrary for *;
    using PoolIdLibrary for PoolKey;

    MiningZap zap;
    address user = makeAddr("zapUser");

    function setUp() public override {
        super.setUp();
        zap = new MiningZap(manager, posm, permit2, engine, key);
        vm.deal(user, 100 ether);
        _mint(alice, 1 ether, true); // a deeper pool than the 0.02 ETH launch
    }

    /// Same split the website uses: constant-product optimum on the pool's virtual ETH reserve, with the 3.3% fee.
    function _split(uint256 amount) internal view returns (uint256) {
        uint256 L = manager.getLiquidity(key.toId());
        uint256 reserve = Math.mulDiv(L, 1 << 96, _currentSqrtPrice());
        uint256 f = 329; // 1 - 0.97 * 0.997 = 0.03291 (scaled by 1e4)
        uint256 twoMinusF = 20_000 - f;
        uint256 oneMinusF = 10_000 - f;
        uint256 a = Math.sqrt(reserve * reserve * twoMinusF * twoMinusF + 4 * oneMinusF * 10_000 * amount * reserve);
        return (a - reserve * twoMinusF) / (2 * oneMinusF);
    }

    /// What the website sends as one EIP-5792 batch (or two transactions): zapAndMint, then subscribe as the owner.
    function _zapAndSubscribe(uint256 amount, uint256 ethToSwap) internal returns (uint256 tokenId, uint128 liq) {
        vm.startPrank(user);
        (tokenId, liq) = zap.zapAndMint{value: amount}(ethToSwap, 0, block.timestamp + 600, address(0));
        posm.subscribe(tokenId, address(engine), "");
        vm.stopPrank();
    }

    function test_zapAndMint_mintsToCaller_noApprovalLeft() public {
        uint256 treasuryBefore = hook.treasuryBalance();
        uint256 s = _split(0.1 ether); // computed first: a view call inside the args would consume vm.prank
        vm.prank(user);
        (uint256 tokenId, uint128 liq) = zap.zapAndMint{value: 0.1 ether}(s, 0, block.timestamp, address(0));

        assertEq(IERC721(address(posm)).ownerOf(tokenId), user);
        assertEq(posm.getPositionLiquidity(tokenId), liq);
        assertEq(IApproved(address(posm)).getApproved(tokenId), address(0), "the zap keeps no rights over the NFT");
        assertEq(address(zap).balance, 0);
        assertEq(token.balanceOf(address(zap)), 0);
        assertGt(hook.treasuryBalance(), treasuryBefore, "hook fee charged on the swap part");
        assertGt(100 ether - user.balance, 0.099 ether, "almost all ETH went into the position");
    }

    function test_zap_thenSubscribe_mines() public {
        (uint256 tokenId,) = _zapAndSubscribe(0.1 ether, _split(0.1 ether));
        assertEq(address(posm.subscriber(tokenId)), address(engine));
        (,,, address owner,,) = engine.miners(tokenId);
        assertEq(owner, user, "rewards belong to the caller");
        _roll(100);
        (uint256 b,) = engine.pending(tokenId);
        assertGt(b, 0);
        uint256 before = token.balanceOf(user);
        vm.prank(user);
        engine.claim(tokenId);
        assertEq(token.balanceOf(user) - before, b);
    }

    function test_zap_splitLeavesLittleDust() public {
        uint256 amount = 0.2 ether;
        _zapAndSubscribe(amount, _split(amount));
        uint256 ethRefund = user.balance - (100 ether - amount);
        uint256 p = _currentSqrtPrice();
        uint256 primeInEth = Math.mulDiv(token.balanceOf(user), 1 << 192, p * p);
        assertLt(ethRefund + primeInEth, amount / 100, "dust < 1%");
    }

    function test_onlyOwnerCanSubscribe() public {
        vm.prank(user);
        (uint256 tokenId,) = zap.zapAndMint{value: 0.1 ether}(0.05 ether, 0, block.timestamp, address(0));
        vm.prank(bob);
        vm.expectRevert();
        posm.subscribe(tokenId, address(engine), "");
    }

    function test_zap_minLiquidity() public {
        vm.prank(user);
        vm.expectRevert();
        zap.zapAndMint{value: 0.1 ether}(0.05 ether, type(uint128).max, block.timestamp, address(0));
    }

    function test_zap_deadlineAndSplitChecks() public {
        vm.startPrank(user);
        vm.expectRevert(MiningZap.Expired.selector);
        zap.zapAndMint{value: 0.1 ether}(0.05 ether, 0, block.timestamp - 1, address(0));
        vm.expectRevert(MiningZap.BadSwapAmount.selector);
        zap.zapAndMint{value: 0.1 ether}(0.1 ether, 0, block.timestamp, address(0));
        vm.expectRevert(MiningZap.BadSwapAmount.selector);
        zap.zapAndMint{value: 0.1 ether}(0, 0, block.timestamp, address(0));
        vm.stopPrank();
    }

    function test_zap_rejectsStrayEthAndForeignCallbacks() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(zap).call{value: 1}("");
        assertFalse(ok);
        vm.expectRevert(MiningZap.OnlyPoolManager.selector);
        zap.unlockCallback(abi.encode(uint256(1)));
    }

    function test_zap_constructorChecksKey() public {
        PoolKey memory bad = key;
        bad.fee = 500;
        vm.expectRevert(MiningZap.InvalidPoolKey.selector);
        new MiningZap(manager, posm, permit2, engine, bad);
        bad = key;
        bad.hooks = IHooks(address(0xdead));
        vm.expectRevert(MiningZap.InvalidPoolKey.selector);
        new MiningZap(manager, posm, permit2, engine, bad);
    }

    function testFuzz_zap(uint256 amount, uint256 splitBps) public {
        amount = bound(amount, 0.001 ether, 1 ether);
        splitBps = bound(splitBps, 3_000, 7_000);
        (uint256 tokenId, uint128 liq) = _zapAndSubscribe(amount, amount * splitBps / 10_000);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), user);
        assertGt(liq, 0);
        assertEq(address(zap).balance, 0);
        assertEq(token.balanceOf(address(zap)), 0);
        assertEq(engine.totalLiquidity(), posm.getPositionLiquidity(tokenId - 1) + liq);
    }

    // ------------------------------------------------------------------
    // Referrals
    // ------------------------------------------------------------------

    event Referred(address indexed user, address indexed referrer);

    function _zapRef(address who, address referrer) internal returns (uint256 tokenId, uint128 liq) {
        vm.deal(who, who.balance + 1 ether);
        vm.prank(who);
        return zap.zapAndMint{value: 0.01 ether}(0.005 ether, 0, block.timestamp, referrer);
    }

    function test_referral_bindsOnFirstZap() public {
        vm.expectEmit(true, true, false, false, address(zap));
        emit Referred(user, bob);
        (uint256 id, uint128 liq) = _zapRef(user, bob);
        assertEq(zap.referrerOf(user), bob);
        assertEq(IERC721(address(posm)).ownerOf(id), user);
        assertGt(liq, 0);
    }

    function test_referral_firstBindingWins() public {
        _zapRef(user, bob);
        vm.recordLogs();
        _zapRef(user, carol);
        assertEq(zap.referrerOf(user), bob);
        bytes32 topic = keccak256("Referred(address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) assertTrue(logs[i].topics[0] != topic, "no second Referred");
    }

    function test_referral_selfIgnored() public {
        (uint256 id,) = _zapRef(user, user);
        assertEq(zap.referrerOf(user), address(0));
        assertEq(IERC721(address(posm)).ownerOf(id), user);
    }

    function test_referral_twoCycleIgnored() public {
        _zapRef(alice, bob); // alice referred by bob
        (uint256 id,) = _zapRef(bob, alice); // bob cannot be referred by alice
        assertEq(zap.referrerOf(alice), bob);
        assertEq(zap.referrerOf(bob), address(0));
        assertEq(IERC721(address(posm)).ownerOf(id), bob);
    }

    function test_referral_zeroAddressNoBinding() public {
        _zapRef(user, address(0));
        assertEq(zap.referrerOf(user), address(0));
    }

    function test_referral_doesNotChangeTheMint() public {
        uint256 snap = vm.snapshotState();
        (, uint128 a) = _zapRef(user, address(0));
        vm.revertToState(snap);
        (, uint128 b) = _zapRef(user, bob);
        assertEq(a, b, "same liquidity with or without a referrer");
    }
}
