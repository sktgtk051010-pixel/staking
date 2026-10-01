// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {StakeToken} from "../src/StakeToken.sol";
import {RewardToken} from "../src/RewardToken.sol";
import {BoostCredential} from "../src/BoostCredential.sol";
import {TimeBoostStaking} from "../src/TimeBoostStaking.sol";

/// @title 部署脚本
/// @notice 部署 4 个合约，将 BoostCredential owner 转给 Staking，并注入初始奖励
/// @dev 运行方式：forge script script/Deploy.s.sol:DeployScript --rpc-url sepolia --broadcast
contract DeployScript is Script {
    /// @notice 初始周期奖励：100,000 RT / 30 天
    uint256 public constant INITIAL_REWARD = 100_000 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        StakeToken stakeToken = new StakeToken();
        console.log("StakeToken (ST):", address(stakeToken));

        RewardToken rewardToken = new RewardToken();
        console.log("RewardToken (RT):", address(rewardToken));

        BoostCredential boostCredential = new BoostCredential();
        console.log("BoostCredential:", address(boostCredential));

        TimeBoostStaking staking = new TimeBoostStaking(
            address(stakeToken),
            address(rewardToken),
            address(boostCredential)
        );
        console.log("TimeBoostStaking:", address(staking));

        boostCredential.transferOwnership(address(staking));
        console.log("BoostCredential owner transferred to Staking");

        rewardToken.mint(deployer, INITIAL_REWARD);
        rewardToken.approve(address(staking), INITIAL_REWARD);
        staking.notifyRewardAmount(INITIAL_REWARD);
        console.log("Initial reward injected:", INITIAL_REWARD / 1e18, "RT");
        console.log("Reward rate (per sec):", staking.rewardRate());
        console.log("Period finish:", staking.periodFinish());

        vm.stopBroadcast();

        console.log("=== Deployment complete ===");
    }
}
