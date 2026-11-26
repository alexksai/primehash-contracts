// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title GenesisReserve
/// @notice Holds the 210,000 PRIME genesis supply and owns all protocol liquidity.
///         - `launch` creates the ETH/PRIME pool and its first full-range position with at most 21,000 PRIME.
///         - `addLiquidity` lets the treasury add the remaining PRIME to the pool over time, paired with ETH.
///         PRIME can leave this contract ONLY as pool liquidity. Liquidity positions are owned by this contract
///         forever: there is no function to remove liquidity or transfer the NFTs. The treasury can only collect
///         the normal 0.30% LP fees those positions earn.
///         Protocol positions are never subscribed to MiningEngine, so they earn no mining rewards.
contract GenesisReserve {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;
    uint256 public constant INITIAL_LIQUIDITY_PRIME = 21_000e18;
    /// @notice Sent to the deployer at launch to fund leaderboard bonuses (210k genesis = 21k launch LP + 100k
    ///         leaderboard bonus + 89k reserve for later liquidity).
    uint256 public constant LEADERBOARD_BONUS = 100_000e18;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable treasury;
    address public immutable deployer;

    bool public launched;
    PoolKey public poolKey;
    IERC20 public token;
    uint256[] public positions;

    event Launched(PoolId indexed poolId, uint160 sqrtPriceX96, uint256 tokenId, uint256 primeUsed, uint256 ethUsed);
    event ReserveLiquidityAdded(uint256 indexed tokenId, uint256 liquidity, uint256 primeUsed, uint256 ethUsed);
    event FeesCollected(uint256 indexed tokenId);
    event LeaderboardBonusSent(address indexed to, uint256 amount);

    error OnlyDeployer();
    error OnlyTreasury();
    error AlreadyLaunched();
    error NotLaunched();
    error PriceOutOfRange(uint160 current);
    error TooMuchPrime();
    error InvalidPoolKey();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, IAllowanceTransfer _permit2, address _treasury) {
        require(_treasury != address(0), "treasury = 0");
        poolManager = _poolManager;
        positionManager = _positionManager;
        permit2 = _permit2;
        treasury = _treasury;
        deployer = msg.sender;
    }

    /// @notice Initializes the pool at `sqrtPriceX96` and mints the first protocol position. Once, by the deployer.
    /// @dev The hook only allows this contract to initialize the pool, so the starting price cannot be front-run.
    ///      Unused ETH is sent to the treasury.
    function launch(PoolKey calldata key, uint160 sqrtPriceX96, uint128 liquidity) external payable {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (launched) revert AlreadyLaunched();
        if (!key.currency0.isAddressZero() || key.tickSpacing != 60) revert InvalidPoolKey();
        launched = true;
        poolKey = key;
        token = IERC20(Currency.unwrap(key.currency1));

        token.forceApprove(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);

        poolManager.initialize(key, sqrtPriceX96);

        uint256 primeBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance - msg.value;
        uint256 tokenId = _mint(liquidity, INITIAL_LIQUIDITY_PRIME, block.timestamp);
        uint256 primeUsed = primeBefore - token.balanceOf(address(this));
        emit Launched(key.toId(), sqrtPriceX96, tokenId, primeUsed, ethBefore + msg.value - address(this).balance);

        token.safeTransfer(deployer, LEADERBOARD_BONUS);
        emit LeaderboardBonusSent(deployer, LEADERBOARD_BONUS);
        _refundEth();
    }

    /// @notice Adds a full-range protocol position using reserve PRIME and the ETH sent. Treasury only.
    /// @param minSqrtPriceX96 / maxSqrtPriceX96 reverts if the current pool price is outside this band
    ///        (protection against price manipulation right before the call).
    function addLiquidity(
        uint128 liquidity,
        uint256 maxPrime,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        uint256 deadline
    ) external payable onlyTreasury returns (uint256 tokenId) {
        if (!launched) revert NotLaunched();
        (uint160 current,,,) = poolManager.getSlot0(poolKey.toId());
        if (current < minSqrtPriceX96 || current > maxSqrtPriceX96) revert PriceOutOfRange(current);

        uint256 primeBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance - msg.value;
        tokenId = _mint(liquidity, maxPrime, deadline);
        uint256 primeUsed = primeBefore - token.balanceOf(address(this));
        emit ReserveLiquidityAdded(tokenId, liquidity, primeUsed, ethBefore + msg.value - address(this).balance);
        _refundEth();
    }

    /// @notice Collects the LP fees of a protocol position to the treasury. Liquidity is not touched.
    function collectFees(uint256 tokenId) external onlyTreasury {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, treasury);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesCollected(tokenId);
    }

    function reserveBalance() external view returns (uint256) {
        return address(token) == address(0) ? 0 : token.balanceOf(address(this));
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function _mint(uint128 liquidity, uint256 maxPrime, uint256 deadline) private returns (uint256 tokenId) {
        if (maxPrime > type(uint128).max) revert TooMuchPrime();
        tokenId = positionManager.nextTokenId();

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            uint256(liquidity),
            uint128(msg.value),
            uint128(maxPrime),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, address(this));
        positionManager.modifyLiquidities{value: msg.value}(abi.encode(actions, params), deadline);
        positions.push(tokenId);
    }

    function _refundEth() private {
        uint256 bal = address(this).balance;
        if (bal != 0) {
            (bool ok,) = treasury.call{value: bal}("");
            require(ok, "refund failed");
        }
    }

    /// @dev Receives unused ETH swept back by PositionManager.
    receive() external payable {}
}
