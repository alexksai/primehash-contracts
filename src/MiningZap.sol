// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MiningEngine} from "./MiningEngine.sol";

/// @title MiningZap
/// @notice "Start mining with ETH only": swaps part of the ETH for PRIME in the PrimeHash pool and mints a
///         full-range position owned by the caller, in one call. Nothing is kept between calls: unused ETH and
///         PRIME are refunded at the end. No admin, no stored user funds, no signatures.
contract MiningZap is IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    MiningEngine public immutable engine;
    IERC20 public immutable token;
    PoolKey internal key;

    /// @notice Who referred each user (bookkeeping only). Referral rewards are paid off-chain by the team in PRIME,
    ///         pro rata to the active mining liquidity of referred users. First binding wins forever.
    mapping(address user => address referrer) public referrerOf;

    event Referred(address indexed user, address indexed referrer);

    event Zapped(
        address indexed owner, uint256 indexed tokenId, uint256 ethIn, uint256 ethSwapped, uint256 primeBought, uint256 liquidity
    );

    error Expired();
    error BadSwapAmount();
    error InsufficientLiquidity(uint256 liquidity, uint256 minLiquidity);
    error OnlyPoolManager();
    error InvalidPoolKey();
    error RefundFailed();

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, IAllowanceTransfer _permit2, MiningEngine _engine, PoolKey memory _key) {
        if (
            !_key.currency0.isAddressZero() || Currency.unwrap(_key.currency1) != address(_engine.token())
                || address(_key.hooks) != _engine.hook() || _key.fee != 3000 || _key.tickSpacing != 60
        ) revert InvalidPoolKey();
        poolManager = _poolManager;
        positionManager = _positionManager;
        engine = _engine;
        token = IERC20(Currency.unwrap(_key.currency1));
        key = _key;
        token.forceApprove(address(_permit2), type(uint256).max);
        _permit2.approve(address(token), address(_positionManager), type(uint160).max, type(uint48).max);
    }

    /// @notice Turns `msg.value` ETH into a full-range position owned by the caller: swaps `ethToSwap` for PRIME,
    ///         pairs the rest with it, refunds leftovers. The caller then subscribes the position to the
    ///         MiningEngine themselves (as its owner): batched with this call by wallets that support EIP-5792,
    ///         otherwise as a second transaction. No signatures, no approvals of the caller's NFTs.
    /// @param ethToSwap    ETH sold for PRIME first (about half; the website computes the best split)
    /// @param minLiquidity reverts below this (slippage / sandwich protection)
    /// @param deadline     timestamp limit
    /// @param referrer     who referred the caller (address(0) = none); recorded once, never reverts the zap
    function zapAndMint(uint256 ethToSwap, uint128 minLiquidity, uint256 deadline, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity)
    {
        if (block.timestamp > deadline) revert Expired();
        if (ethToSwap == 0 || ethToSwap >= msg.value || ethToSwap > uint256(uint128(type(int128).max))) revert BadSwapAmount();

        // 0. Referral: first binding wins, no self-referral, no direct 2-cycle
        if (
            referrer != address(0) && referrer != msg.sender && referrerOf[msg.sender] == address(0)
                && referrerOf[referrer] != msg.sender
        ) {
            referrerOf[msg.sender] = referrer;
            emit Referred(msg.sender, referrer);
        }

        // 1. ETH -> PRIME in the PrimeHash pool (the 3% hook fee applies like any swap)
        uint256 bought = abi.decode(poolManager.unlock(abi.encode(ethToSwap)), (uint256));

        // 2. Largest full-range position the remaining ETH + bought PRIME allow, at the post-swap price
        uint256 ethLeft = msg.value - ethToSwap;
        uint256 primeBal = token.balanceOf(address(this));
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), ethLeft, primeBal
        );
        liquidity -= liquidity / 1_000_000 + 1; // rounding margin: amounts are rounded up when minting
        if (liquidity < minLiquidity) revert InsufficientLiquidity(liquidity, minLiquidity);

        // 3. Mint to the caller; this contract pays (PRIME via Permit2, ETH as value)
        tokenId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(ethLeft), uint128(primeBal), msg.sender, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        positionManager.modifyLiquidities{value: ethLeft}(abi.encode(actions, params), deadline);

        // 4. Refund leftovers
        uint256 restPrime = token.balanceOf(address(this));
        if (restPrime != 0) token.safeTransfer(msg.sender, restPrime);
        uint256 restEth = address(this).balance;
        if (restEth != 0) {
            (bool ok,) = msg.sender.call{value: restEth}("");
            if (!ok) revert RefundFailed();
        }
        emit Zapped(msg.sender, tokenId, msg.value, ethToSwap, bought, liquidity);
    }

    /// @dev Exact-input ETH -> PRIME swap, settled and taken within the same unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint256 ethIn = abi.decode(data, (uint256));
        BalanceDelta delta =
            poolManager.swap(key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), bytes(""));
        uint256 owed = uint256(uint128(-delta.amount0()));
        uint256 out = uint256(uint128(delta.amount1()));
        poolManager.settle{value: owed}();
        poolManager.take(key.currency1, address(this), out);
        return abi.encode(out);
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    /// @dev ETH only arrives from the PoolManager / PositionManager (SWEEP of unused ETH) during a zap.
    receive() external payable {
        if (msg.sender != address(positionManager) && msg.sender != address(poolManager)) revert OnlyPoolManager();
    }
}
