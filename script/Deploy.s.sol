// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

/// forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract Deploy is Script {
    function run() external returns (StakingRewards staking) {
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        staking = new StakingRewards(stakingToken, rewardToken, owner);
        vm.stopBroadcast();

        console2.log("StakingRewards deployed at", address(staking));
    }
}
