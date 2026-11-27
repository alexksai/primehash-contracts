// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MiningEngine} from "../src/MiningEngine.sol";
import {MiningZap} from "../src/MiningZap.sol";
import {PrimeHashHook} from "../src/PrimeHashHook.sol";
import {RigShop} from "../src/RigShop.sol";

/// @notice Deploys RigShop next to the live PrimeHash contracts (Ethereum mainnet).
///   forge script script/DeployShop.s.sol --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
contract DeployShop is Script {
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    MiningZap constant ZAP = MiningZap(payable(0xB10871397f5Ac0fFDd55E14572F51614C79d888D));

    function run() external returns (RigShop shop) {
        MiningEngine engine = ZAP.engine();
        address treasury = PrimeHashHook(payable(engine.hook())).treasury();
        vm.startBroadcast();
        shop = new RigShop(POSM, PERMIT2, engine, ZAP.poolKey(), treasury);
        vm.stopBroadcast();
        console.log("RigShop", address(shop));
        console.log("treasury", treasury);
    }
}
