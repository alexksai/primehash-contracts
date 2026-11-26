// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PrimeHashFixture} from "../utils/PrimeHashFixture.sol";
import {Emission} from "../../src/libraries/Emission.sol";
import {MiningEngine} from "../../src/MiningEngine.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";

/// @notice Random sequences of mint / subscribe / modify / swap / claim / burn / transfer / time.
contract MiningHandler is PrimeHashFixture {
    address[] public users;
    uint256[] public ids;
    mapping(uint256 => bool) public burned;

    constructor() {
        setUp();
        // The mainnet PoolManager is a singleton holding the ETH of every pool; emulate that, otherwise a fuzzed
        // sequence that drains this tiny pool leaves the PoolManager without ETH to pay the hook fee.
        vm.deal(address(manager), 10_000 ether);
        users.push(alice);
        users.push(bob);
        users.push(carol);
    }

    function engineAddr() external view returns (MiningEngine) {
        return engine;
    }

    function posmAddr() external view returns (IPositionManager) {
        return posm;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function _owner(uint256 id) internal view returns (address) {
        return IERC721(address(posm)).ownerOf(id);
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        if (ids.length == 0) return (0, false);
        id = ids[seed % ids.length];
        ok = !burned[id];
    }

    function mint(uint256 userSeed, uint256 ethSeed, bool sub) external {
        address u = users[userSeed % users.length];
        (uint256 id,) = _mint(u, bound(ethSeed, 0.001 ether, 5 ether), sub);
        ids.push(id);
    }

    function subscribe(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok || address(posm.subscriber(id)) != address(0)) return;
        _subscribe(_owner(id), id);
    }

    function unsubscribe(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok || address(posm.subscriber(id)) == address(0)) return;
        _unsubscribe(_owner(id), id);
    }

    function increase(uint256 seed, uint256 ethSeed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        uint256 l = posm.getPositionLiquidity(id);
        if (l == 0) return;
        // add 10%..50% of the position; ETH max is generous, the surplus is swept back
        _increase(_owner(id), id, l * bound(ethSeed, 10, 50) / 100 + 1, 1_000 ether);
    }

    function decrease(uint256 seed, uint256 pct) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        uint256 l = posm.getPositionLiquidity(id);
        if (l == 0) return; // Uniswap rejects modifying an empty position
        _decrease(_owner(id), id, l * bound(pct, 0, 100) / 100);
    }

    function burn(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        _burn(_owner(id), id);
        burned[id] = true;
    }

    function transfer(uint256 seed, uint256 toSeed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        address from = _owner(id);
        vm.prank(from);
        IERC721(address(posm)).transferFrom(from, users[toSeed % users.length], id);
    }

    function claim(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        _claim(_owner(id), id);
    }

    function claimOwed(uint256 userSeed) external {
        vm.prank(users[userSeed % users.length]);
        engine.claimOwed();
    }

    function buy(uint256 amount) external {
        _buy(bound(amount, 1e9, 2 ether));
    }

    function sell(uint256 amount) external {
        _sell(bound(amount, 1e18, 2_000_000e18));
    }

    function roll(uint256 blocks) external {
        _roll(bound(blocks, 1, 3 * engine.STREAM_BLOCKS()));
    }
}

contract MiningInvariantsTest is Test {
    MiningHandler h;
    MiningEngine engine;

    function setUp() public {
        h = new MiningHandler();
        engine = h.engineAddr();
        targetContract(address(h));
        // Only the handler actions (not inherited helpers such as setUp / deployPermit2).
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = MiningHandler.mint.selector;
        selectors[1] = MiningHandler.subscribe.selector;
        selectors[2] = MiningHandler.unsubscribe.selector;
        selectors[3] = MiningHandler.increase.selector;
        selectors[4] = MiningHandler.decrease.selector;
        selectors[5] = MiningHandler.burn.selector;
        selectors[6] = MiningHandler.transfer.selector;
        selectors[7] = MiningHandler.claim.selector;
        selectors[8] = MiningHandler.claimOwed.selector;
        selectors[9] = MiningHandler.buy.selector;
        selectors[10] = MiningHandler.sell.selector;
        selectors[11] = MiningHandler.roll.selector;
        selectors[12] = MiningHandler.roll.selector; // time passes often
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// totalLiquidity equals the sum of the positions' liquidity; subscribed positions match PositionManager.
    function invariant_liquidityAccounting() public view {
        uint256 sum;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.ids(i);
            (uint128 l,,,,,) = engine.miners(id);
            sum += l;
            if (!h.burned(id)) {
                if (address(h.posmAddr().subscriber(id)) == address(engine)) {
                    assertEq(l, h.posmAddr().getPositionLiquidity(id), "subscribed liquidity mirrors posm");
                } else {
                    assertEq(l, 0, "unsubscribed positions have no power");
                }
            }
        }
        assertEq(sum, engine.totalLiquidity());
    }

    /// The engine always holds enough ETH for everything owed.
    function invariant_ethSolvency() public view {
        uint256 owed;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) {
            (, uint256 e) = engine.pending(h.ids(i));
            owed += e;
        }
        for (uint256 i; i < h.usersLength(); ++i) {
            (, uint128 e) = engine.owed(h.users(i));
            owed += e;
        }
        assertLe(owed, address(engine).balance);
        assertLe(engine.totalEthClaimed(), engine.totalEthReceived());
    }

    /// PRIME paid + owed never exceeds the halving schedule; supply never exceeds the cap.
    function invariant_primeEmission() public view {
        uint256 owed;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 b,) = engine.pending(h.ids(i));
            owed += b;
        }
        for (uint256 i; i < h.usersLength(); ++i) {
            (uint128 b,) = engine.owed(h.users(i));
            owed += b;
        }
        uint256 scheduled = Emission.between(engine.startBlock(), engine.startBlock(), vm.getBlockNumber());
        assertLe(owed + engine.totalPrimeClaimed(), scheduled);
        assertLe(engine.totalPrimeMined(), scheduled);
        assertLe(engine.token().totalSupply(), 21_000_000e18);
    }
}
