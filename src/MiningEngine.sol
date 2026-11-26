// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {ISubscriber} from "v4-periphery/interfaces/ISubscriber.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

import {PrimeToken} from "./PrimeToken.sol";
import {Emission} from "./libraries/Emission.sol";
import {IMiningEngine} from "./interfaces/IMiningEngine.sol";

/// @title MiningEngine — Proof of Liquidity
/// @notice Full-range LP positions of the PrimeHash pool that subscribe to this contract (through the Uniswap v4
///         PositionManager) become "miners". Mining power = position liquidity / total subscribed liquidity.
///         Miners earn:
///           - PRIME, emitted every Ethereum block according to the halving schedule;
///           - ETH, from the miners' half of the hook fee, streamed over STREAM_BLOCKS (~1 day) so that
///             just-in-time liquidity cannot capture the fee of a single swap.
/// @dev Rewards belong to the position NFT (tokenId), not to an address: whoever owns the NFT can claim.
///      Subscriber callbacks never revert after subscription, so they can never block a liquidity withdrawal.
///      There is no admin. The deployer can only call `initialize` once, to bind the pool.
contract MiningEngine is IMiningEngine, ISubscriber, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Full range for tick spacing 60.
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;
    /// @notice ETH from fees is distributed linearly over this many blocks (~24h).
    uint256 public constant STREAM_BLOCKS = 7200;

    uint256 private constant ACC_PRECISION = 1e36;
    uint256 private constant RATE_PRECISION = 1e18;

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    IPositionManager public immutable positionManager;
    /// @notice The PRIME token, bound once in `initialize` (it must name this engine as its minter).
    PrimeToken public token;
    address private immutable deployer;

    // ---------------------------------------------------------------------
    // Global state
    // ---------------------------------------------------------------------

    // Storage is packed so that the subscriber callbacks stay cheap: PositionManager on mainnet gives
    // `notifyUnsubscribe` only 150,000 gas.

    // slot: 8 + 3 * 64 bits
    bool public initialized;
    uint64 public startBlock;
    uint64 public lastUpdateBlock;
    uint64 public ethPeriodFinish;

    // slot. Sum of liquidity of full-range positions in one pool is bounded by the pool's
    // maxLiquidityPerTick (< 2^128), so uint128 cannot overflow.
    uint128 public totalLiquidity;
    uint128 public totalPrimeMined; // PRIME attributed to miners (stats)

    uint256 public accPrimePerLiquidity;
    uint256 public accEthPerLiquidity;
    /// @notice ETH stream: wei per block, scaled by 1e18.
    uint256 public ethRate;

    bytes25 public poolId; // truncated PoolId, as stored in PositionInfo
    address public hook;

    // Stats
    uint256 public totalEthReceived;
    uint256 public totalPrimeClaimed;
    uint256 public totalEthClaimed;

    // ---------------------------------------------------------------------
    // Positions
    // ---------------------------------------------------------------------

    /// @dev While a position is subscribed its owner cannot change: PositionManager unsubscribes on every
    ///      NFT transfer. So `owner` (recorded at subscribe) is the owner for the whole mining period, and
    ///      when mining stops for any reason (unsubscribe, transfer, burn) the rewards are credited to them.
    struct Miner {
        uint128 liquidity; // 0 when not subscribed
        uint128 primeOwed; // max supply 2.1e25 fits easily
        uint96 ethOwed; // 7.9e28 wei max, far above all ETH in existence
        address owner; // owner during the current/last subscription (also keeps this slot non-zero = cheap writes)
        uint256 primeDebt;
        uint256 ethDebt;
    }

    struct Owed {
        uint128 primeAmount;
        uint128 ethAmount;
    }

    mapping(uint256 tokenId => Miner) public miners;

    /// @notice Rewards of positions that stopped mining (unsubscribed, transferred or burned),
    ///         claimable by the account that owned the position while it was mining.
    mapping(address account => Owed) public owed;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event Initialized(PoolId indexed poolId, address hook, uint256 startBlock);
    event MinerStarted(uint256 indexed tokenId, address indexed owner, uint256 liquidity);
    event MinerLiquidityChanged(uint256 indexed tokenId, uint256 liquidity);
    event MinerStopped(uint256 indexed tokenId, address indexed owner, uint256 primeCredited, uint256 ethCredited);
    event EthNotified(address indexed from, uint256 amount, uint256 newRate, uint256 periodFinish);
    event Claimed(uint256 indexed tokenId, address indexed to, uint256 primeAmount, uint256 ethAmount);

    error OnlyDeployer();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidPoolKey();
    error OnlyPositionManager();
    error WrongPool();
    error NotFullRange();
    error NotOwner();
    error EthTransferFailed();

    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) revert OnlyPositionManager();
        _;
    }

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
        deployer = msg.sender;
    }

    /// @notice Binds the engine to the PrimeHash pool and starts emission. Callable once, by the deployer.
    function initialize(PoolKey calldata key) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (initialized) revert AlreadyInitialized();
        address t = Currency.unwrap(key.currency1);
        if (
            !key.currency0.isAddressZero() || t.code.length == 0 || key.fee != 3000 || key.tickSpacing != 60
                || address(key.hooks).code.length == 0
        ) revert InvalidPoolKey();
        if (PrimeToken(t).minter() != address(this)) revert InvalidPoolKey();

        initialized = true;
        token = PrimeToken(t);
        PoolId id = key.toId();
        poolId = bytes25(PoolId.unwrap(id));
        hook = address(key.hooks);
        // Accumulators start at 1 so that debts are never 0 and their updates never pay the 20k zero->non-zero cost
        // (only differences matter, so this does not change any reward).
        accPrimePerLiquidity = 1;
        accEthPerLiquidity = 1;
        startBlock = uint64(block.number);
        lastUpdateBlock = uint64(block.number);
        emit Initialized(id, hook, block.number);
    }

    // ---------------------------------------------------------------------
    // ETH rewards
    // ---------------------------------------------------------------------

    /// @inheritdoc IMiningEngine
    /// @dev Called by the hook on every swap. Anyone may also add ETH for miners.
    function notifyEth() external payable {
        if (msg.value == 0) return;
        _update();
        uint256 amount = msg.value * RATE_PRECISION;
        uint256 finish = ethPeriodFinish;
        if (block.number < finish) amount += (finish - block.number) * ethRate;
        ethRate = amount / STREAM_BLOCKS;
        ethPeriodFinish = uint64(block.number + STREAM_BLOCKS);
        totalEthReceived += msg.value;
        emit EthNotified(msg.sender, msg.value, ethRate, block.number + STREAM_BLOCKS);
    }

    // ---------------------------------------------------------------------
    // PositionManager subscriber callbacks
    // ---------------------------------------------------------------------

    /// @dev May revert: an ineligible position simply cannot subscribe.
    function notifySubscribe(uint256 tokenId, bytes memory) external onlyPositionManager {
        if (!initialized) revert NotInitialized();
        (, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        if (info.poolId() != poolId) revert WrongPool();
        if (info.tickLower() != TICK_LOWER || info.tickUpper() != TICK_UPPER) revert NotFullRange();

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        Miner storage m = miners[tokenId];
        // Normally a no-op; settles a stale entry if an earlier unsubscribe notification ran out of gas.
        _stopAndCredit(tokenId, m);
        _update();
        _accrue(m); // sets debts to the current accumulators
        totalLiquidity += liquidity;
        m.liquidity = liquidity;
        m.owner = owner;
        emit MinerStarted(tokenId, owner, liquidity);
    }

    /// @dev Must not revert: it runs inside every increase / decrease of a subscribed position.
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta) external onlyPositionManager {
        _update();
        Miner storage m = miners[tokenId];
        _accrue(m);
        uint256 oldL = m.liquidity;
        uint256 newL;
        if (liquidityChange >= 0) {
            newL = oldL + uint256(liquidityChange);
        } else {
            uint256 dec = uint256(-liquidityChange);
            newL = dec >= oldL ? 0 : oldL - dec;
        }
        uint256 newTotal = uint256(totalLiquidity) - oldL + newL;
        if (newTotal > type(uint128).max) {
            newL -= newTotal - type(uint128).max; // unreachable in practice (see totalLiquidity)
            newTotal = type(uint128).max;
        }
        m.liquidity = uint128(newL);
        totalLiquidity = uint128(newTotal);
        emit MinerLiquidityChanged(tokenId, newL);
    }

    /// @dev Runs with a gas cap inside a try/catch in PositionManager; kept cheap. If it ever runs out of gas,
    ///      anyone can fix the accounting with `sync(tokenId)`.
    ///      Also runs on every NFT transfer (after the transfer): rewards go to the previous owner.
    function notifyUnsubscribe(uint256 tokenId) external onlyPositionManager {
        _stopAndCredit(tokenId, miners[tokenId]);
    }

    /// @dev Must not revert. Rewards are credited to the owner.
    function notifyBurn(uint256 tokenId, address, PositionInfo, uint256, BalanceDelta) external onlyPositionManager {
        _stopAndCredit(tokenId, miners[tokenId]);
        delete miners[tokenId];
    }

    /// @notice Settles a position that is no longer subscribed but is still counted (only possible if the
    ///         unsubscribe notification ran out of gas). Anyone can call it.
    function sync(uint256 tokenId) public {
        Miner storage m = miners[tokenId];
        if (m.liquidity != 0 && address(positionManager.subscriber(tokenId)) != address(this)) {
            _stopAndCredit(tokenId, m);
        }
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------

    /// @notice Claims the rewards of a position that is mining. Caller must own the NFT.
    function claim(uint256 tokenId) external returns (uint256 primeAmount, uint256 ethAmount) {
        return claimTo(tokenId, msg.sender);
    }

    /// @notice Same as `claim`, paying to `to` (e.g. when the owner is a contract that cannot receive ETH).
    function claimTo(uint256 tokenId, address to) public nonReentrant returns (uint256 primeAmount, uint256 ethAmount) {
        (primeAmount, ethAmount) = _claimPosition(tokenId);
        _pay(to, primeAmount, ethAmount);
    }

    function claimMany(uint256[] calldata tokenIds) external nonReentrant returns (uint256 primeAmount, uint256 ethAmount) {
        for (uint256 i; i < tokenIds.length; ++i) {
            (uint256 b, uint256 e) = _claimPosition(tokenIds[i]);
            primeAmount += b;
            ethAmount += e;
        }
        _pay(msg.sender, primeAmount, ethAmount);
    }

    /// @notice Claims the rewards of positions that stopped mining while the caller owned them
    ///         (unsubscribed, transferred away or burned).
    function claimOwed() external returns (uint256 primeAmount, uint256 ethAmount) {
        return claimOwedTo(msg.sender);
    }

    function claimOwedTo(address to) public nonReentrant returns (uint256 primeAmount, uint256 ethAmount) {
        Owed memory o = owed[msg.sender];
        delete owed[msg.sender];
        primeAmount = o.primeAmount;
        ethAmount = o.ethAmount;
        _pay(to, primeAmount, ethAmount);
        emit Claimed(0, msg.sender, primeAmount, ethAmount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Unclaimed rewards of a position that is currently mining.
    function pending(uint256 tokenId) external view returns (uint256 primeAmount, uint256 ethAmount) {
        (uint256 accB, uint256 accE) = _accumulatorsNow();
        Miner storage m = miners[tokenId];
        primeAmount = m.primeOwed + m.liquidity * (accB - m.primeDebt) / ACC_PRECISION;
        ethAmount = m.ethOwed + m.liquidity * (accE - m.ethDebt) / ACC_PRECISION;
    }

    /// @notice Mining power of a position, in basis points (10000 = 100%).
    function miningPowerBps(uint256 tokenId) external view returns (uint256) {
        uint256 total = totalLiquidity;
        return total == 0 ? 0 : uint256(miners[tokenId].liquidity) * 10_000 / total;
    }

    /// @notice PRIME reward of the current block and the block at which the next halving happens.
    function currentReward() external view returns (uint256 perBlock, uint256 nextHalvingBlock) {
        if (!initialized) return (Emission.INITIAL_REWARD, 0);
        return (Emission.rewardAt(startBlock, block.number), Emission.nextHalving(startBlock, block.number));
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _update() internal {
        // one SLOAD for initialized / startBlock / lastUpdateBlock / ethPeriodFinish
        uint256 last = lastUpdateBlock;
        if (!initialized || block.number <= last) return;
        uint256 finish = ethPeriodFinish;

        uint256 total = totalLiquidity;
        if (total == 0) {
            // No miners: this period's PRIME emission is never minted; the ETH stream is paused.
            if (finish > last) ethPeriodFinish = uint64(finish + block.number - last);
        } else {
            uint256 mined = Emission.between(startBlock, last, block.number);
            if (mined != 0) {
                accPrimePerLiquidity += mined * ACC_PRECISION / total;
                totalPrimeMined += uint128(mined);
            }
            uint256 ethEnd = finish < block.number ? finish : block.number;
            if (ethEnd > last) {
                accEthPerLiquidity += (ethEnd - last) * ethRate * (ACC_PRECISION / RATE_PRECISION) / total;
            }
        }
        lastUpdateBlock = uint64(block.number);
    }

    function _accumulatorsNow() internal view returns (uint256 accB, uint256 accE) {
        accB = accPrimePerLiquidity;
        accE = accEthPerLiquidity;
        uint256 last = lastUpdateBlock;
        uint256 total = totalLiquidity;
        if (!initialized || block.number <= last || total == 0) return (accB, accE);
        accB += Emission.between(startBlock, last, block.number) * ACC_PRECISION / total;
        uint256 ethEnd = ethPeriodFinish < block.number ? ethPeriodFinish : block.number;
        if (ethEnd > last) accE += (ethEnd - last) * ethRate * (ACC_PRECISION / RATE_PRECISION) / total;
    }

    function _accrue(Miner storage m) internal {
        uint256 accB = accPrimePerLiquidity;
        uint256 accE = accEthPerLiquidity;
        uint256 l = m.liquidity;
        uint256 dB = m.primeDebt;
        uint256 dE = m.ethDebt;
        if (l != 0) {
            if (accB != dB) m.primeOwed += uint128(l * (accB - dB) / ACC_PRECISION);
            if (accE != dE) m.ethOwed += uint96(l * (accE - dE) / ACC_PRECISION);
        }
        if (accB != dB) m.primeDebt = accB;
        if (accE != dE) m.ethDebt = accE;
    }

    function _claimPosition(uint256 tokenId) internal returns (uint256 primeAmount, uint256 ethAmount) {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) revert NotOwner();
        Miner storage m = miners[tokenId];
        if (m.liquidity != 0 && address(positionManager.subscriber(tokenId)) != address(this)) {
            _stopAndCredit(tokenId, m); // stale entry: rewards go to owed[m.owner]
            return (0, 0);
        }
        _update();
        _accrue(m);
        primeAmount = m.primeOwed;
        ethAmount = m.ethOwed;
        m.primeOwed = 0;
        m.ethOwed = 0;
        emit Claimed(tokenId, msg.sender, primeAmount, ethAmount);
    }

    /// @dev Stops mining for a position and moves its rewards to the account that owned it while mining.
    ///      Never reverts; cheap enough for the 150k gas cap of `notifyUnsubscribe`.
    function _stopAndCredit(uint256 tokenId, Miner storage m) internal {
        uint256 l = m.liquidity;
        if (l == 0 && m.primeOwed == 0 && m.ethOwed == 0) return;
        _update();
        _accrue(m);
        if (l != 0) {
            totalLiquidity -= uint128(l);
            m.liquidity = 0;
        }
        uint256 b = m.primeOwed;
        uint256 e = m.ethOwed;
        if (b != 0 || e != 0) {
            Owed storage o = owed[m.owner];
            o.primeAmount += uint128(b);
            o.ethAmount += uint128(e);
            m.primeOwed = 0;
            m.ethOwed = 0;
        }
        emit MinerStopped(tokenId, m.owner, b, e);
    }

    function _pay(address to, uint256 primeAmount, uint256 ethAmount) internal {
        if (primeAmount != 0) {
            totalPrimeClaimed += primeAmount;
            token.mint(to, primeAmount);
        }
        if (ethAmount != 0) {
            totalEthClaimed += ethAmount;
            (bool ok,) = to.call{value: ethAmount}("");
            if (!ok) revert EthTransferFailed();
        }
    }
}
