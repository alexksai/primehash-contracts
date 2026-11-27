// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MiningEngine} from "../../src/MiningEngine.sol";
import {MiningZap} from "../../src/MiningZap.sol";
import {RigShop} from "../../src/RigShop.sol";

/// @notice RigShop against the live PrimeHash deployment on an Ethereum mainnet fork.
///         MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc RigShopForkTest -vv
contract RigShopForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    MiningEngine constant ENGINE = MiningEngine(payable(0xDb5658c775D77c4792C5A8A944F674bF00752E89));
    MiningZap constant ZAP = MiningZap(payable(0xB10871397f5Ac0fFDd55E14572F51614C79d888D));
    IERC20 constant PRIME = IERC20(0xAafa34D12F0CAe4A8395916807b1433D63f27612);
    address constant TREASURY = 0x48Ad93ae9264463e4FFCdA64a45AaCf5d1821781;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    RigShop shop;
    PoolKey key;
    address buyer = makeAddr("buyer");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        key = ZAP.poolKey();
        shop = new RigShop(POSM, PERMIT2, ENGINE, key, TREASURY);
        // The treasury is an EIP-7702 account on mainnet; strip its code so pranked calls behave like an EOA.
        vm.etch(TREASURY, "");
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        PRIME.approve(address(shop), type(uint256).max);
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _sqrtP() internal view returns (uint160 p) {
        (p,,,) = POSM.poolManager().getSlot0(key.toId());
    }

    function _createMany(uint8 model, uint8 rarity, uint256 count, uint256 eth) internal returns (uint256[] memory ids) {
        uint160 p = _sqrtP();
        uint256 bal = PRIME.balanceOf(TREASURY);
        vm.prank(TREASURY);
        ids = shop.create{value: eth}(model, rarity, count, bal, p - p / 100, p + p / 100, block.timestamp);
    }

    function _create(uint8 model, uint256 eth) internal returns (uint256 id, uint256 price) {
        id = _createMany(model, 0, 1, eth)[0];
        (price,,,) = shop.rigs(id);
    }

    function test_create_plugsInAndPrices() public onlyFork {
        uint256 stray = address(POSM).balance; // swept back to the treasury by the mint
        uint256 shopEth0 = address(shop).balance; // the fork address may already hold ETH
        uint256 shopPrime0 = PRIME.balanceOf(address(shop));
        uint256 eth0 = TREASURY.balance;
        uint256 prime0 = PRIME.balanceOf(TREASURY);
        uint256 l0 = ENGINE.totalLiquidity();
        (uint256 id, uint256 price) = _create(3, 0.002 ether);

        uint256 ethUsed = eth0 + stray - TREASURY.balance;
        uint256 primeUsed = prime0 - PRIME.balanceOf(TREASURY);
        console.log("ethUsed", ethUsed, "primeUsed", primeUsed / 1e18);
        console.log("price", price);
        assertApproxEqRel(ethUsed, 0.002 ether, 2e12, "ETH is the limiting side, ~all used");
        // value at creation = ETH + PRIME at the pool price; price must be that + 20%
        uint256 p = _sqrtP();
        uint256 primeInEth = primeUsed * (1 << 96) / p * (1 << 96) / p;
        assertApproxEqRel(price, (ethUsed + primeInEth) * 12_000 / 10_000, 1e15, "price = (ETH + PRIME value) x 1.2, within 0.1%");
        assertEq(price, ethUsed * 2 * 12_000 / 10_000, "price = value x 1.2");
        assertEq(IERC721(address(POSM)).ownerOf(id), address(shop));
        assertEq(address(POSM.subscriber(id)), address(ENGINE), "mining while listed");
        assertGt(ENGINE.totalLiquidity(), l0);
        (uint128 pr, uint8 model,,) = shop.rigs(id);
        assertEq(pr, price);
        assertEq(model, 3);
        assertEq(PRIME.balanceOf(address(shop)), shopPrime0, "no PRIME left in the shop");
        assertEq(address(shop).balance, shopEth0, "no ETH left in the shop");
    }

    function test_buy_burnsMined_paysTreasury_buyerPlugsIn() public onlyFork {
        (uint256 id, uint256 price) = _create(0, 0.002 ether);
        vm.roll(block.number + 300);
        (uint256 minedPrime, uint256 minedEth) = ENGINE.pending(id);
        assertGt(minedPrime, 0, "rig mined while on display");

        uint256 dead0 = PRIME.balanceOf(DEAD);
        uint256 t0 = TREASURY.balance;
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        shop.buy{value: price}(id);

        assertEq(IERC721(address(POSM)).ownerOf(id), buyer);
        assertEq(PRIME.balanceOf(DEAD) - dead0, minedPrime, "mined PRIME burned");
        assertEq(TREASURY.balance - t0, price + minedEth, "price + mined ETH to treasury");
        assertEq(shop.totalBurned(), minedPrime);
        assertEq(address(POSM.subscriber(id)), address(0), "unplugged by the transfer");
        (uint128 owedP, uint128 owedE) = ENGINE.owed(address(shop));
        assertEq(owedP + owedE, 0, "nothing left credited to the shop");
        assertEq(shop.listedRigs().length, 0);

        // plug in: buyer starts from zero and earns from now on
        vm.prank(buyer);
        POSM.subscribe(id, address(ENGINE), "");
        (uint256 p0,) = ENGINE.pending(id);
        assertEq(p0, 0, "no retroactive rewards");
        vm.roll(block.number + 10);
        (uint256 p1,) = ENGINE.pending(id);
        assertGt(p1, 0, "mining for the buyer");
        vm.prank(buyer);
        ENGINE.claim(id);
        assertEq(PRIME.balanceOf(buyer), p1);
    }

    function test_buy_reverts() public onlyFork {
        (uint256 id, uint256 price) = _create(1, 0.001 ether);
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(RigShop.WrongPrice.selector, price));
        shop.buy{value: price - 1}(id);
        vm.expectRevert(abi.encodeWithSelector(RigShop.WrongPrice.selector, price));
        shop.buy{value: price + 1}(id);
        vm.expectRevert(RigShop.NotForSale.selector);
        shop.buy{value: price}(id + 1000);
        shop.buy{value: price}(id);
        vm.expectRevert(RigShop.NotForSale.selector);
        shop.buy{value: price}(id); // already sold
        vm.stopPrank();
    }

    function test_onlyTreasury() public onlyFork {
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        vm.expectRevert(RigShop.OnlyTreasury.selector);
        shop.create{value: 0.001 ether}(0, 0, 1, 0, 0, type(uint160).max, block.timestamp);
        vm.stopPrank();
        (uint256 id,) = _create(0, 0.001 ether);
        vm.prank(buyer);
        vm.expectRevert(RigShop.OnlyTreasury.selector);
        shop.delist(id);
    }

    function test_create_priceGuard() public onlyFork {
        uint160 p = _sqrtP();
        vm.prank(TREASURY);
        vm.expectRevert(RigShop.PriceOutOfRange.selector);
        shop.create{value: 0.001 ether}(0, 0, 1, 1000e18, p + 1, p + 2, block.timestamp);
    }

    function test_createMany_identicalRigs_modelAndRarity() public onlyFork {
        uint256 stray = address(POSM).balance;
        uint256 eth0 = TREASURY.balance;
        uint256 prime0 = PRIME.balanceOf(TREASURY);
        uint256 shopEth0 = address(shop).balance; // the fork address may already hold ETH
        uint256[] memory ids = _createMany(6, 2, 5, 0.005 ether);
        assertEq(ids.length, 5);
        assertEq(shop.listedRigs().length, 5);
        (uint128 price0,,,) = shop.rigs(ids[0]);
        uint256 liq0 = POSM.getPositionLiquidity(ids[0]);
        for (uint256 i; i < 5; ++i) {
            (uint128 pr, uint8 model, uint8 rarity,) = shop.rigs(ids[i]);
            assertEq(model, 6);
            assertEq(rarity, 2);
            assertApproxEqRel(pr, price0, 1e12, "same price");
            assertEq(POSM.getPositionLiquidity(ids[i]), liq0, "same size");
            assertEq(address(POSM.subscriber(ids[i])), address(ENGINE));
            assertEq(IERC721(address(POSM)).ownerOf(ids[i]), address(shop));
        }
        uint256 ethUsed = eth0 + stray - TREASURY.balance;
        assertApproxEqRel(ethUsed, 0.005 ether, 2e12, "all ETH used, rest refunded");
        assertApproxEqRel(uint256(price0) * 5, ethUsed * 2 * 12_000 / 10_000, 1e12, "5 x price = total value x 1.2");
        assertGt(prime0 - PRIME.balanceOf(TREASURY), 0);
        assertEq(address(shop).balance, shopEth0);
        assertEq(PRIME.balanceOf(address(shop)), 0);
    }

    function test_createMany_badCount() public onlyFork {
        uint160 p = _sqrtP();
        vm.startPrank(TREASURY);
        vm.expectRevert(RigShop.BadCount.selector);
        shop.create{value: 0.001 ether}(0, 0, 0, 1000e18, p - p / 100, p + p / 100, block.timestamp);
        vm.expectRevert(RigShop.BadCount.selector);
        shop.create{value: 0.001 ether}(0, 0, 21, 1000e18, p - p / 100, p + p / 100, block.timestamp);
        vm.stopPrank();
    }

    function test_delist_returnsRig_burnsMined() public onlyFork {
        (uint256 a,) = _create(0, 0.001 ether);
        (uint256 b,) = _create(1, 0.001 ether);
        (uint256 c,) = _create(2, 0.001 ether);
        assertEq(shop.listedRigs().length, 3);
        vm.roll(block.number + 50);
        (uint256 mined,) = ENGINE.pending(b);
        uint256 dead0 = PRIME.balanceOf(DEAD);
        vm.prank(TREASURY);
        shop.delist(b);
        assertEq(IERC721(address(POSM)).ownerOf(b), TREASURY);
        assertEq(PRIME.balanceOf(DEAD) - dead0, mined);
        uint256[] memory l = shop.listedRigs();
        assertEq(l.length, 2);
        assertTrue((l[0] == a && l[1] == c) || (l[0] == c && l[1] == a));
        vm.prank(TREASURY);
        vm.expectRevert(RigShop.NotForSale.selector);
        shop.delist(b);
    }

    function test_unexpectedEthRejected() public onlyFork {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(shop).call{value: 1}("");
        assertFalse(ok);
    }
}
