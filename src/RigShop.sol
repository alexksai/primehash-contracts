// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MiningEngine} from "./MiningEngine.sol";

/// @title RigShop: plug & play rigs
/// @notice The treasury builds ready full-range ETH/PRIME positions ("rigs") and lists them here at a fixed ETH price:
///         the position's value at creation + 20%. While listed, a rig mines for the shop; at sale everything it
///         mined is removed from circulation (PRIME is burned, mined ETH goes to the treasury) and the buyer gets
///         the bare position NFT, which they plug into the MiningEngine themselves (`subscribe`).
/// @dev The treasury can only create and delist rigs. It cannot change a price, touch a sold rig, or hold buyer funds:
///      payments go straight to the treasury in `buy`. No upgradeability.
contract RigShop is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    /// @notice Price premium over the rig's value at creation: 20%.
    uint256 public constant PREMIUM_BPS = 2000;
    /// @notice Where mined PRIME is burned (PRIME has no burn function).
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    /// @notice Most rigs built in one `create` call.
    uint256 public constant MAX_BATCH = 20;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    MiningEngine public immutable engine;
    IERC20 public immutable token;
    address public immutable treasury;
    PoolKey internal key;

    struct Rig {
        uint128 priceEth; // 0 = not for sale
        uint8 model; // visual model (art / name on the website)
        uint8 rarity; // 0 common, 1 uncommon, 2 rare, 3 epic, 4 legendary
        uint64 listedAt; // block
    }

    mapping(uint256 tokenId => Rig) public rigs;
    uint256[] internal listed;
    mapping(uint256 tokenId => uint256) internal listedIndex; // index + 1

    uint256 public totalBurned; // PRIME burned from rigs mined while listed
    uint256 public totalSold;
    uint256 public totalRevenue; // ETH

    event RigListed(
        uint256 indexed tokenId, uint8 model, uint8 rarity, uint256 priceEth, uint256 liquidity, uint256 ethUsed, uint256 primeUsed
    );
    event RigSold(uint256 indexed tokenId, address indexed buyer, uint256 priceEth, uint256 primeBurned, uint256 ethMined);
    event RigDelisted(uint256 indexed tokenId);
    event MinedBurned(uint256 primeBurned, uint256 ethToTreasury);

    error OnlyTreasury();
    error BadCount();
    error NotForSale();
    error WrongPrice(uint256 expected);
    error PriceOutOfRange();
    error Expired();
    error InvalidPoolKey();
    error EthTransferFailed();
    error UnexpectedEth();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor(IPositionManager _positionManager, IAllowanceTransfer _permit2, MiningEngine _engine, PoolKey memory _key, address _treasury) {
        if (
            !_key.currency0.isAddressZero() || Currency.unwrap(_key.currency1) != address(_engine.token())
                || address(_key.hooks) != _engine.hook() || _key.fee != 3000 || _key.tickSpacing != 60
        ) revert InvalidPoolKey();
        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        engine = _engine;
        token = IERC20(Currency.unwrap(_key.currency1));
        treasury = _treasury;
        key = _key;
        token.forceApprove(address(_permit2), type(uint256).max);
        _permit2.approve(address(token), address(_positionManager), type(uint160).max, type(uint48).max);
    }

    // ---------------------------------------------------------------------
    // Treasury
    // ---------------------------------------------------------------------

    /// @notice Builds `count` identical rigs from `msg.value` ETH and up to `maxPrime` PRIME of the treasury (approved
    ///         to this contract), split equally. Each rig is plugged into the MiningEngine and listed at
    ///         2 x its ETH used x 1.20. Leftovers are refunded.
    /// @param model  visual model of the rigs (website art / name)
    /// @param rarity rarity tier shown on the website (0 = common ... 4 = legendary)
    /// @param minSqrtPriceX96 / maxSqrtPriceX96 pool price bounds (sandwich protection)
    function create(
        uint8 model,
        uint8 rarity,
        uint256 count,
        uint256 maxPrime,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        uint256 deadline
    ) external payable onlyTreasury nonReentrant returns (uint256[] memory tokenIds) {
        if (block.timestamp > deadline) revert Expired();
        if (count == 0 || count > MAX_BATCH) revert BadCount();
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        if (sqrtP < minSqrtPriceX96 || sqrtP > maxSqrtPriceX96) revert PriceOutOfRange();

        uint256 ethBefore = address(this).balance - msg.value; // normally 0; ETH can be forced in
        uint256 primeBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), maxPrime);

        uint256 ethEach = msg.value / count;
        uint256 primeEach = maxPrime / count;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), ethEach, primeEach
        );
        liquidity -= liquidity / 1_000_000 + 1; // rounding margin: amounts are rounded up when minting

        tokenIds = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            tokenIds[i] = _build(model, rarity, liquidity, ethEach, primeEach, deadline);
        }

        // refunds: what was not used goes back to the treasury
        uint256 restPrime = token.balanceOf(address(this)) - primeBefore;
        uint256 restEth = address(this).balance - ethBefore;
        if (restPrime != 0) token.safeTransfer(msg.sender, restPrime);
        if (restEth != 0) _sendEth(msg.sender, restEth);
    }

    function _build(uint8 model, uint8 rarity, uint128 liquidity, uint256 ethMax, uint256 primeMax, uint256 deadline)
        internal
        returns (uint256 tokenId)
    {
        tokenId = positionManager.nextTokenId();
        // SWEEP returns the PositionManager's whole ETH balance, including ETH others left there: measure it.
        uint256 stray = address(positionManager).balance;
        uint256 b0 = address(this).balance;
        uint256 p0 = token.balanceOf(address(this));
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(ethMax), uint128(primeMax), address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        positionManager.modifyLiquidities{value: ethMax}(abi.encode(actions, params), deadline);
        positionManager.subscribe(tokenId, address(engine), "");

        uint256 ethUsed = b0 + stray - address(this).balance;
        // A full-range position holds equal values of both tokens at the current price: value = 2 x ETH used.
        uint256 priceEth = ethUsed * 2 * (10_000 + PREMIUM_BPS) / 10_000;
        rigs[tokenId] = Rig(uint128(priceEth), model, rarity, uint64(block.number));
        listed.push(tokenId);
        listedIndex[tokenId] = listed.length;
        emit RigListed(tokenId, model, rarity, priceEth, liquidity, ethUsed, p0 - token.balanceOf(address(this)));
    }

    /// @notice Takes an unsold rig back (what it mined is burned, like at a sale).
    function delist(uint256 tokenId) external onlyTreasury nonReentrant {
        if (rigs[tokenId].priceEth == 0) revert NotForSale();
        _unlist(tokenId);
        _burnMined(tokenId);
        IERC721(address(positionManager)).transferFrom(address(this), treasury, tokenId);
        emit RigDelisted(tokenId);
    }

    // ---------------------------------------------------------------------
    // Buyers
    // ---------------------------------------------------------------------

    /// @notice Buys a rig for exactly its listed price. The caller receives the position NFT and plugs it in
    ///         with PositionManager.subscribe(tokenId, engine, "") (batched with this call by EIP-5792 wallets).
    function buy(uint256 tokenId) external payable nonReentrant {
        uint256 price = rigs[tokenId].priceEth;
        if (price == 0) revert NotForSale();
        if (msg.value != price) revert WrongPrice(price);
        _unlist(tokenId);
        (uint256 burned, uint256 ethMined) = _burnMined(tokenId);
        totalSold += 1;
        totalRevenue += price;
        _sendEth(treasury, price);
        // Unsubscribes the position (PositionManager does it on every transfer); nothing is left to credit.
        IERC721(address(positionManager)).transferFrom(address(this), msg.sender, tokenId);
        emit RigSold(tokenId, msg.sender, price, burned, ethMined);
    }

    /// @notice Burns rewards the engine credited to the shop outside a sale (e.g. if an unsubscribe ran out of
    ///         gas and someone called `engine.sync`). Anyone can call it.
    function burnOwed() external nonReentrant {
        uint256 p0 = token.balanceOf(address(this));
        uint256 e0 = address(this).balance;
        engine.claimOwedTo(address(this));
        _burnAndForward(token.balanceOf(address(this)) - p0, address(this).balance - e0);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function listedRigs() external view returns (uint256[] memory) {
        return listed;
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _unlist(uint256 tokenId) internal {
        delete rigs[tokenId];
        uint256 i = listedIndex[tokenId] - 1;
        uint256 last = listed[listed.length - 1];
        listed[i] = last;
        listedIndex[last] = i + 1;
        listed.pop();
        delete listedIndex[tokenId];
    }

    /// @dev Claims what the rig mined while listed: PRIME is burned, ETH goes to the treasury.
    function _burnMined(uint256 tokenId) internal returns (uint256 prime, uint256 eth) {
        (prime, eth) = engine.claimTo(tokenId, address(this));
        _burnAndForward(prime, eth);
    }

    function _burnAndForward(uint256 prime, uint256 eth) internal {
        if (prime != 0) {
            token.safeTransfer(BURN, prime);
            totalBurned += prime;
        }
        if (eth != 0) _sendEth(treasury, eth);
        if (prime != 0 || eth != 0) emit MinedBurned(prime, eth);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev ETH arrives only from the engine (mined ETH) and the PositionManager (unused ETH at create).
    receive() external payable {
        if (msg.sender != address(engine) && msg.sender != address(positionManager)) revert UnexpectedEth();
    }
}
