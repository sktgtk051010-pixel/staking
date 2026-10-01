// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakeToken} from "../../src/StakeToken.sol";
import {RewardToken} from "../../src/RewardToken.sol";
import {BoostCredential} from "../../src/BoostCredential.sol";
import {TimeBoostStaking} from "../../src/TimeBoostStaking.sol";

/// @notice Fork 测试：在主网 fork 环境下验证合约基本流程
/// @dev 运行方式：forge test --match-contract ForkTest --fork-url $MAINNET_RPC_URL
contract ForkTest is Test {
    StakeToken public stakeToken;
    RewardToken public rewardToken;
    BoostCredential public boostCredential;
    TimeBoostStaking public staking;

    address public owner = address(this);
    address public alice = makeAddr("fork_test_user_alice_98765");
    address public bob = makeAddr("fork_test_user_bob_98765");

    uint256 public constant INITIAL_REWARD = 10_000_000 ether;

    function setUp() public {
        // fork 主网
        vm.createSelectFork("mainnet");

        // 部署合约（和单元测试相同的部署流程）
        stakeToken = new StakeToken();
        rewardToken = new RewardToken();
        boostCredential = new BoostCredential();

        staking = new TimeBoostStaking(
            address(stakeToken),
            address(rewardToken),
            address(boostCredential)
        );

        boostCredential.transferOwnership(address(staking));

        stakeToken.mint(alice, 1_000_000 ether);
        stakeToken.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(staking), type(uint256).max);

        rewardToken.mint(owner, INITIAL_REWARD);
        rewardToken.approve(address(staking), INITIAL_REWARD);
        staking.notifyRewardAmount(INITIAL_REWARD);
    }

    /// @notice Fork 环境下质押成功以及领取奖励成功
    function test_Fork_StakeSuccess_GetReward() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); // 30天档

        assertEq(stakeId, 1);
        assertEq(staking.totalStaked(), 100 ether);
        assertEq(stakeToken.balanceOf(address(staking)), 100 ether);

        skip(1 days);

        uint256 balanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        uint256 balanceAfter = rewardToken.balanceOf(alice);

        assertGt(balanceAfter, balanceBefore);
    }

    /// @notice Fork 环境下奖励随时间增长（90天档）
    function test_Fork_RewardAccrues() public {
        vm.prank(alice);
        staking.stake(1000 ether, 2); // 90天档

        skip(1 days);

        uint256 earned = staking.earned(alice);
        assertGt(earned, 0);
    }

    /// @notice Fork 环境下取回本金成功
    function test_Fork_Unstake() public {
        vm.prank(bob);
        staking.stake(5000 ether, 0);

        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); 

        skip(30 days);

        uint256 balanceBefore = stakeToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(stakeId);

        assertEq(stakeToken.balanceOf(alice) - balanceBefore, 100 ether);
    }

    /// @notice Fork 环境下早期凭证自动铸造
    function test_Fork_EarlyCredential() public {
        vm.prank(alice);
        staking.stake(100 ether, 2); // 90天档

        assertTrue(boostCredential.userHasBoost(alice));
        assertEq(boostCredential.balanceOf(alice, 0), 1);
    }

    /// @notice Fork 环境下多笔独立质押
    function test_Fork_MultipleStakes() public {
        vm.prank(alice);
        uint256 id1 = staking.stake(100 ether, 1); 
        vm.prank(alice);
        uint256 id2 = staking.stake(200 ether, 3); 

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(staking.getUserStakeIds(alice).length, 2);
        assertEq(staking.totalStaked(), 300 ether);
    }

    /// @notice Fork 环境下周期结束后奖励停止
    function test_Fork_PeriodEnds() public {
        vm.prank(alice);
        staking.stake(1000 ether, 1);

        skip(30 days); 
        uint256 earned1 = staking.earned(alice);

        skip(10 days);
        uint256 earned2 = staking.earned(alice);

        assertEq(earned1, earned2);
    }

    /// @notice Revert：解锁前取回本金失败
    function test_Fork_Revert_UnstakeBeforeUnlock() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); // 30天档

        skip(1 days); 

        vm.prank(alice);
        vm.expectRevert("still locked");
        staking.unstake(stakeId);
    }

    /// @notice Revert：非持有人取回别人的质押失败
    function test_Fork_Revert_NotOwner() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1);

        vm.prank(bob);
        vm.expectRevert("not owner");
        staking.unstake(stakeId);
    }

    /// @notice Revert：非管理员注入奖励失败
    function test_Fork_Revert_NotOwnerNotify() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.notifyRewardAmount(100 ether);
    }
}
