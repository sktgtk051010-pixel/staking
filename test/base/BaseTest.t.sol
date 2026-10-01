// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakeToken} from "../../src/StakeToken.sol";
import {RewardToken} from "../../src/RewardToken.sol";
import {BoostCredential} from "../../src/BoostCredential.sol";
import {TimeBoostStaking} from "../../src/TimeBoostStaking.sol";

abstract contract BaseTest is Test {
    StakeToken public stakeToken;
    RewardToken public rewardToken;
    BoostCredential public boostCredential;
    TimeBoostStaking public staking;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant INITIAL_REWARD = 10_000_000 ether;
    uint256 public constant REWARDS_DURATION = 30 days;

    function setUp() public virtual {
        stakeToken = new StakeToken();
        rewardToken = new RewardToken();
        boostCredential = new BoostCredential();

        staking = new TimeBoostStaking(
            address(stakeToken),
            address(rewardToken),
            address(boostCredential)
        );

        boostCredential.transferOwnership(address(staking));

        // 给用户 mint 质押代币
        stakeToken.mint(alice, 1_000_000 ether);
        stakeToken.mint(bob, 1_000_000 ether);
        stakeToken.mint(carol, 1_000_000 ether);

        vm.prank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.prank(carol);
        stakeToken.approve(address(staking), type(uint256).max);

        rewardToken.mint(owner, INITIAL_REWARD);
        rewardToken.approve(address(staking), INITIAL_REWARD);
        staking.notifyRewardAmount(INITIAL_REWARD);
    }

    /// @notice 跳过指定天数
    function skipDays(uint256 numDays) internal {
        skip(numDays * 1 days);
    }
}
