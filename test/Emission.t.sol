// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Emission} from "../src/libraries/Emission.sol";
import {PrimeToken} from "../src/PrimeToken.sol";

contract EmissionTest is Test {
    uint256 constant H = Emission.HALVING_INTERVAL;

    function test_firstEpoch() public pure {
        assertEq(Emission.between(100, 100, 100 + H), 5e18 * H);
        assertEq(Emission.rewardAt(100, 100), 5e18);
        assertEq(Emission.rewardAt(100, 100 + H - 1), 5e18);
        assertEq(Emission.rewardAt(100, 100 + H), 2.5e18);
        assertEq(Emission.rewardAt(100, 99), 0);
    }

    function test_totalSupply_fitsCap() public pure {
        uint256 total = Emission.between(0, 0, H * 70);
        assertLe(total, 20_790_000e18);
        assertGt(total, 20_789_999e18);
        assertLe(total + 210_000e18, 21_000_000e18);
        assertEq(Emission.between(0, H * 64, H * 100), 0);
    }

    function testFuzz_additive(uint256 a, uint256 b, uint256 c) public pure {
        a = bound(a, 0, H * 66);
        b = bound(b, a, H * 66);
        c = bound(c, b, H * 66);
        assertEq(Emission.between(0, a, b) + Emission.between(0, b, c), Emission.between(0, a, c));
    }

    function test_nextHalving() public pure {
        assertEq(Emission.nextHalving(10, 10), 10 + H);
        assertEq(Emission.nextHalving(10, 10 + H), 10 + 2 * H);
    }
}

contract PrimeTokenTest is Test {
    function test_genesisAndCap() public {
        address reserve = makeAddr("reserve");
        PrimeToken t = new PrimeToken(address(this), reserve);
        assertEq(t.balanceOf(reserve), 210_000e18);
        assertEq(t.name(), "PrimeHash");
        assertEq(t.symbol(), "PRIME");

        t.mint(address(1), 20_790_000e18);
        assertEq(t.totalSupply(), 21_000_000e18);
        vm.expectRevert(PrimeToken.CapExceeded.selector);
        t.mint(address(1), 1);
    }

    function test_onlyMinter() public {
        PrimeToken t = new PrimeToken(address(this), address(this));
        vm.prank(makeAddr("x"));
        vm.expectRevert(PrimeToken.OnlyMinter.selector);
        t.mint(address(1), 1);
    }
}
