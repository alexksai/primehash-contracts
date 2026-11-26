// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PrimeToken} from "../src/PrimeToken.sol";
import {MiningEngine} from "../src/MiningEngine.sol";
import {PrimeHashHook} from "../src/PrimeHashHook.sol";
import {GenesisReserve} from "../src/GenesisReserve.sol";
import {MiningZap} from "../src/MiningZap.sol";
import {IMiningEngine} from "../src/interfaces/IMiningEngine.sol";

/// @notice Shared deployment logic for the deploy script and the fork tests.
abstract contract PrimeHashDeployer {
    /// Deterministic CREATE2 deployer proxy (same address on every EVM chain).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;
    uint256 internal constant LAUNCH_PRIME = 21_000e18;

    struct Uniswap {
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
    }

    struct Deployment {
        GenesisReserve reserve;
        MiningEngine engine;
        PrimeToken token;
        PrimeHashHook hook;
        MiningZap zap;
        PoolKey key;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    function _uniswap(uint256 chainId) internal pure returns (Uniswap memory u) {
        IAllowanceTransfer permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        if (chainId == 1) {
            return Uniswap(
                IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
                IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e),
                permit2
            );
        }
        if (chainId == 11155111) {
            return Uniswap(
                IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
                IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4),
                permit2
            );
        }
        revert("unsupported chain");
    }

    /// @dev Must be called by the deployer EOA (broadcast in scripts, prank in tests); it becomes the only
    ///      address allowed to call `engine.initialize` and `reserve.launch` (both one-shot, done here).
    function _deploy(Uniswap memory u, address treasury, uint256 launchEth) internal returns (Deployment memory d) {
        require(treasury != address(0), "treasury not set");
        require(launchEth > 0, "launch ETH not set");

        // 1. Reserve  2. Engine  3. PRIME (minter = engine, genesis minted into the reserve)
        d.reserve = new GenesisReserve(u.poolManager, u.positionManager, u.permit2, treasury);
        d.engine = new MiningEngine(u.positionManager);
        d.token = new PrimeToken(address(d.engine), address(d.reserve));

        // 3. Hook at an address whose low bits encode its permissions
        bytes memory args = abi.encode(
            u.poolManager, IMiningEngine(address(d.engine)), treasury, address(d.token), address(d.reserve)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(PrimeHashHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(PrimeHashHook).creationCode, args));
        require(ok && hookAddr.code.length > 0, "hook deploy failed");
        d.hook = PrimeHashHook(payable(hookAddr));

        // 4. Bind engine to the pool
        d.key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(d.token)), 3000, 60, IHooks(hookAddr));
        d.engine.initialize(d.key);

        // 5. Create the pool + first protocol position: 21,000 PRIME with `launchEth`
        d.sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(LAUNCH_PRIME, 1 << 192, launchEth)));
        d.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            d.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            launchEth,
            LAUNCH_PRIME
        ) * 999 / 1000; // rounding margin; unused ETH goes to the treasury
        d.reserve.launch{value: launchEth}(d.key, d.sqrtPriceX96, d.liquidity);

        // 6. Zap ("start mining with ETH only"): a stateless helper, deployable any time
        d.zap = new MiningZap(u.poolManager, u.positionManager, u.permit2, d.engine, d.key);
    }
}
