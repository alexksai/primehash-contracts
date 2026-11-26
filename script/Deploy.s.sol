// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PrimeHashDeployer} from "./PrimeHashDeployer.sol";

/// @notice Deploys PrimeHash on Ethereum mainnet or Sepolia.
///
///   TREASURY=0x...  LAUNCH_ETH=20000000000000000 \
///   ~/.foundry/bin/forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --broadcast --verify
///
/// Without --broadcast it only simulates (safe to run any time).
/// TREASURY   address that receives the treasury fee and owns the right to add reserve liquidity (use a Safe)
/// LAUNCH_ETH wei paired with 21,000 PRIME in the first position (sets the starting price)
contract Deploy is Script, PrimeHashDeployer {
    using PoolIdLibrary for PoolKey;

    function run() external returns (Deployment memory d) {
        address treasury = vm.envAddress("TREASURY");
        uint256 launchEth = vm.envUint("LAUNCH_ETH");
        Uniswap memory u = _uniswap(block.chainid);

        vm.startBroadcast();
        d = _deploy(u, treasury, launchEth);
        vm.stopBroadcast();

        console.log("chain id         ", block.chainid);
        console.log("GenesisReserve   ", address(d.reserve));
        console.log("MiningEngine     ", address(d.engine));
        console.log("PRIME            ", address(d.token));
        console.log("PrimeHashHook   ", address(d.hook));
        console.log("MiningZap        ", address(d.zap));
        console.log("Treasury         ", treasury);
        console.log("Pool id");
        console.logBytes32(PoolId.unwrap(d.key.toId()));
        console.log("Launch ETH (wei) ", launchEth);
        console.log("PRIME per ETH    ", 21_000e18 * 1e18 / launchEth / 1e18);
    }
}
