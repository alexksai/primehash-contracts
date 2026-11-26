// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title PRIME, the PrimeHash token
/// @notice Plain ERC-20 with a hard cap of 21,000,000. No owner, no transfer tax, no pause, no blacklist.
///         210,000 PRIME genesis is minted once at deployment to the GenesisReserve; everything else can only
///         be minted by MiningEngine, following the halving schedule.
/// @dev Deployed separately from MiningEngine (with the engine as the immutable minter) so that each contract fits
///      in one transaction under the higher code-deposit gas costs.
contract PrimeToken is ERC20, ERC20Permit {
    uint256 public constant MAX_SUPPLY = 21_000_000e18;
    uint256 public constant GENESIS_SUPPLY = 210_000e18;

    /// @notice The only address that can mint: MiningEngine.
    address public immutable minter;

    error OnlyMinter();
    error CapExceeded();

    constructor(address minter_, address genesisRecipient) ERC20("PrimeHash", "PRIME") ERC20Permit("PrimeHash") {
        minter = minter_;
        _mint(genesisRecipient, GENESIS_SUPPLY);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }
}
