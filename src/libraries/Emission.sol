// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Emission — PRIME halving schedule
/// @notice 5 PRIME per Ethereum block, halving every 2,079,000 blocks (~289 days).
///         Total over all epochs: 5 * 2,079,000 * 2 = 20,790,000 PRIME (slightly less because of integer halving).
library Emission {
    uint256 internal constant INITIAL_REWARD = 5e18;
    uint256 internal constant HALVING_INTERVAL = 2_079_000;
    /// @dev After 64 halvings the reward is 0 anyway (5e18 >> 63 == 0).
    uint256 internal constant MAX_EPOCHS = 64;

    /// @notice Reward per block at absolute block `blk`, for a schedule starting at `start`.
    function rewardAt(uint256 start, uint256 blk) internal pure returns (uint256) {
        if (blk < start) return 0;
        uint256 epoch = (blk - start) / HALVING_INTERVAL;
        return epoch >= MAX_EPOCHS ? 0 : INITIAL_REWARD >> epoch;
    }

    /// @notice Total PRIME scheduled for blocks in [from, to).
    function between(uint256 start, uint256 from, uint256 to) internal pure returns (uint256 total) {
        if (from < start) from = start;
        while (from < to) {
            uint256 epoch = (from - start) / HALVING_INTERVAL;
            if (epoch >= MAX_EPOCHS) break;
            uint256 epochEnd = start + (epoch + 1) * HALVING_INTERVAL;
            uint256 end = to < epochEnd ? to : epochEnd;
            total += (end - from) * (INITIAL_REWARD >> epoch);
            from = end;
        }
    }

    /// @notice First block of the next halving epoch.
    function nextHalving(uint256 start, uint256 blk) internal pure returns (uint256) {
        if (blk < start) return start + HALVING_INTERVAL;
        return start + ((blk - start) / HALVING_INTERVAL + 1) * HALVING_INTERVAL;
    }
}
