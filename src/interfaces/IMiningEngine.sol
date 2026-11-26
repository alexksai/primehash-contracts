// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The part of MiningEngine that PrimeHashHook talks to.
interface IMiningEngine {
    /// @notice Receives the miners' share of the hook fee, in native ETH.
    function notifyEth() external payable;
}
