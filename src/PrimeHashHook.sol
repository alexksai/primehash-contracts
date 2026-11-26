// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {IMiningEngine} from "./interfaces/IMiningEngine.sol";

/// @title PrimeHashHook
/// @notice Uniswap v4 hook for the ETH/PRIME pool. On every swap it charges a fixed 3% fee in native ETH,
///         on top of the pool's normal 0.30% LP fee. Half of the hook fee goes to miners (MiningEngine),
///         half is kept for the treasury.
/// @dev The fee is always taken in ETH (currency0), whatever the swap direction or type:
///
///      | direction    | type         | specified | where the fee is taken                         |
///      |--------------|--------------|-----------|------------------------------------------------|
///      | ETH -> PRIME | exact input  | ETH       | beforeSwap: cut from the ETH input             |
///      | PRIME -> ETH | exact output | ETH       | beforeSwap: pool outputs extra ETH for the fee |
///      | PRIME -> ETH | exact input  | PRIME     | afterSwap: cut from the ETH output             |
///      | ETH -> PRIME | exact output | PRIME     | afterSwap: added to the ETH the swapper pays   |
///
///      In every case the fee is 3% of the gross ETH amount that moves on the swapper's side
///      (ETH paid including fee, or ETH output before fee).
///
///      There is no owner and no admin function. All fees are constants.
contract PrimeHashHook is IHooks {
    using SafeCast for uint256;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Standard Uniswap LP fee of the pool (0.30%), paid to liquidity providers by the PoolManager.
    uint24 public constant LP_FEE = 3000;
    int24 public constant TICK_SPACING = 60;

    uint256 public constant BPS = 10_000;
    /// @notice Hook fee: 3.00% of the ETH side of each swap.
    uint256 public constant HOOK_FEE_BPS = 300;
    /// @notice Share of the hook fee that goes to miners (the rest goes to the treasury): 50%.
    uint256 public constant MINER_SHARE_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    IMiningEngine public immutable miningEngine;
    address public immutable treasury;
    /// @notice The PRIME token (currency1 of the pool; currency0 is native ETH).
    address public immutable primeToken;
    /// @notice The only address allowed to initialize the pool (prevents front-running the starting price).
    address public immutable initializer;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// @notice Miner ETH is forwarded to the MiningEngine at most once per PUSH_INTERVAL blocks (~5 min) instead of on
    ///         every swap: it saves traders the ~45k-gas engine call on most swaps. Miners lose nothing: the engine
    ///         streams ETH over ~24h anyway, and anyone can call `flushMinerEth()` at any time.
    uint256 public constant PUSH_INTERVAL = 25;

    // One storage slot (cheap to update on every swap).
    bool public poolInitialized;
    /// @notice Block of the last forward to the MiningEngine.
    uint32 public lastPushBlock;
    /// @notice Miner ETH collected since the last forward (or not deliverable to the engine).
    uint96 public pendingMinerEth;
    /// @notice ETH collected for the treasury, waiting to be withdrawn.
    uint120 public treasuryBalance;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event HookFeeCollected(uint256 fee, uint256 toMiners, uint256 toTreasury);
    event TreasuryWithdrawn(uint256 amount);

    error NotPoolManager();
    error HookNotImplemented();
    error PoolAlreadyInitialized();
    error NotInitializer();
    error InvalidPoolKey();
    error TransferFailed();
    error ZeroAddress();
    error PartialFillNotSupported();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IMiningEngine _miningEngine,
        address _treasury,
        address _primeToken,
        address _initializer
    ) {
        if (_treasury == address(0) || _primeToken == address(0) || _initializer == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        miningEngine = _miningEngine;
        treasury = _treasury;
        primeToken = _primeToken;
        initializer = _initializer;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @dev Exactly one pool can use this hook: native ETH / PRIME, 0.30% LP fee, tick spacing 60,
    ///      initialized by `initializer`.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != initializer) revert NotInitializer();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != primeToken || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidPoolKey();
        poolInitialized = true;
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Takes the fee when ETH is the specified currency.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 fee = _feeOnSpecified(params);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _collect(fee);
        // Positive specified delta = owed to the hook. For exact input it shrinks the amount swapped,
        // for exact output it grows the amount the pool must output.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Takes the fee when ETH is the unspecified currency.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_ethIsSpecified(params)) {
            // The fee was charged in beforeSwap on the full specified amount, so a partial fill (price limit or
            // liquidity exhausted) would overcharge the swapper. Partial fills are therefore not supported.
            uint256 specified = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = _feeOnSpecified(params);
            int128 ethDelta = delta.amount0();
            uint256 swapped = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
            // exact input: pool consumed `specified - fee`; exact output: pool produced `specified + fee`
            uint256 expected = params.amountSpecified < 0 ? specified - fee : specified + fee;
            if (swapped != expected) revert PartialFillNotSupported();
            return (IHooks.afterSwap.selector, 0);
        }

        int128 ethDelta = delta.amount0(); // swapper's perspective: > 0 receives ETH, < 0 pays ETH
        uint256 fee;
        if (ethDelta > 0) {
            // PRIME -> ETH, exact input: fee is cut from the ETH output.
            fee = uint256(uint128(ethDelta)) * HOOK_FEE_BPS / BPS;
        } else {
            // ETH -> PRIME, exact output: fee is added to the ETH the swapper pays,
            // so that it is 3% of the total paid.
            fee = uint256(uint128(-ethDelta)) * HOOK_FEE_BPS / (BPS - HOOK_FEE_BPS);
        }
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        _collect(fee);
        // Positive unspecified delta = owed to the hook: swapper receives less / pays more ETH.
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ---------------------------------------------------------------------
    // Treasury
    // ---------------------------------------------------------------------

    /// @notice Sends the accumulated treasury ETH to the treasury. Anyone can call it.
    function withdrawTreasury() external {
        uint256 amount = treasuryBalance;
        treasuryBalance = 0;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit TreasuryWithdrawn(amount);
    }

    /// @notice Retries delivering miner ETH that MiningEngine could not accept earlier. Anyone can call it.
    function flushMinerEth() external {
        _pushToMiners();
    }

    /// @dev Native ETH arrives from PoolManager.take().
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Fee when ETH is the specified currency.
    ///      Exact input (ETH -> PRIME): cut from the ETH the swapper sends.
    ///      Exact output (PRIME -> ETH): swapper receives exactly `amountSpecified`, the pool outputs
    ///      `amountSpecified + fee`, so the fee is 3% of the gross output.
    function _feeOnSpecified(SwapParams calldata params) private pure returns (uint256) {
        if (params.amountSpecified < 0) return uint256(-params.amountSpecified) * HOOK_FEE_BPS / BPS;
        return uint256(params.amountSpecified) * HOOK_FEE_BPS / (BPS - HOOK_FEE_BPS);
    }

    /// @dev ETH is currency0, so it is the specified currency when (exactInput == zeroForOne).
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _collect(uint256 fee) private {
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        uint256 toMiners = fee * MINER_SHARE_BPS / BPS;
        uint256 toTreasury = fee - toMiners;
        // a single pool's fees cannot approach 2^96 / 2^120 wei
        treasuryBalance += uint120(toTreasury);
        pendingMinerEth += uint96(toMiners);
        if (block.number >= uint256(lastPushBlock) + PUSH_INTERVAL) _pushToMiners();
        emit HookFeeCollected(fee, toMiners, toTreasury);
    }

    /// @dev Never reverts, so a broken MiningEngine can never block swaps.
    /// @dev Never reverts: if the engine call fails the ETH stays pending and is retried later.
    function _pushToMiners() private {
        uint96 amount = pendingMinerEth;
        lastPushBlock = uint32(block.number);
        if (amount == 0) return;
        pendingMinerEth = 0; // state before the external call
        (bool ok,) = address(miningEngine).call{value: amount}(abi.encodeCall(IMiningEngine.notifyEth, ()));
        if (!ok) pendingMinerEth = amount;
    }

    // ---------------------------------------------------------------------
    // Unused hook callbacks
    // ---------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
