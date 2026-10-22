// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./base/BaseTest.t.sol";

contract StakingTest is BaseTest {
    // ============================================================
    //                      质押（stake）
    // ============================================================

    /// @notice 正常路径：用户质押成功，stakeId 从 1 开始
    function test_Stake_Success() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 2);

        (uint256 amount, , uint256 unlockTime, uint256 lockMultiplier) = staking.stakes(stakeId);
        assertEq(stakeId, 1);
        assertEq(amount, 100 ether);
        assertEq(unlockTime, block.timestamp + 90 days);
        assertEq(lockMultiplier, 1.6e18);
    }

    /// @notice 边界：质押数量为 0 时 revert
    function test_Stake_RevertWhen_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("Zero amount");
        staking.stake(0, 0);
    }

    /// @notice 边界：档位下标越界时 revert
    function test_Stake_RevertWhen_InvalidTier() public {
        vm.prank(alice);
        vm.expectRevert("bad tier");
        staking.stake(100 ether, 4); 
    }

    /// @notice 边界：超过最大活跃笔数（50笔）时 revert
    function test_Stake_RevertWhen_TooManyStakes() public {
        vm.startPrank(alice);

        for (uint256 i = 0; i < 50; i++) {
            staking.stake(1 ether, 0);
        }

        vm.expectRevert("too many stakes");
        staking.stake(1 ether, 0);
        vm.stopPrank();
    }

    /// @notice 正常路径：质押后 totalStaked 正确累加（不同档位）
    function test_Stake_UpdatesTotalStaked() public {
        vm.prank(alice);
        staking.stake(100 ether, 2); // 90天档 1.6x → 有效 160
        vm.prank(bob);
        staking.stake(200 ether, 3); // 180天档 2.0x → 有效 400

        assertEq(staking.totalStaked(), 560 ether);
    }

    // ============================================================
    //                      领取奖励（getReward）
    // ============================================================

    /// @notice 正常路径：时间流逝后奖励增长，领取后余额正确
    function test_GetReward_AccruesAndTransfers() public {
        vm.prank(alice);
        staking.stake(1000 ether, 1); // 30天档 1.2x

        skipDays(1);

        uint256 earnedBefore = staking.earned(alice);
        assertGt(earnedBefore, 0);

        uint256 balanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        uint256 balanceAfter = rewardToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, earnedBefore);
    }

    /// @notice 边界：没有质押时领取奖励为 0，不 revert
    function test_GetReward_ZeroWhenNoStake() public {
        vm.prank(alice);
        staking.getReward(); 
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    /// @notice 正常路径：领取后 earned 归零（已结算）
    function test_GetReward_ResetsEarned() public {
        vm.prank(alice);
        staking.stake(1000 ether, 2); // 90天档 1.6x

        skipDays(1);
        vm.prank(alice);
        staking.getReward();

        assertEq(staking.earned(alice), 0);
    }

    // ============================================================
    //                      取回本金（unstake）
    // ============================================================

    /// @notice 正常路径：到期后取回本金，奖励一并结算
    function test_Unstake_Success() public {
        vm.prank(bob);
        staking.stake(5000 ether, 0);

        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); // 30天档

        skipDays(30);

        uint256 stBefore = stakeToken.balanceOf(alice);
        uint256 rtBefore = rewardToken.balanceOf(alice);
        uint256 expectedReward = staking.earned(alice);
        assertGt(expectedReward, 0, "alice should have earned reward");

        vm.prank(alice);
        staking.unstake(stakeId);

        assertEq(stakeToken.balanceOf(alice) - stBefore, 100 ether);
        assertEq(rewardToken.balanceOf(alice) - rtBefore, expectedReward);
        assertEq(staking.totalStaked(), 5000 ether);
        assertEq(staking.getUserStakeIds(alice).length, 0);
    }

    /// @notice 边界：锁仓期内取回 revert
    function test_Unstake_RevertWhen_StillLocked() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); // 30天档

        skipDays(29); 

        vm.prank(alice);
        vm.expectRevert("still locked");
        staking.unstake(stakeId);
    }

    /// @notice 边界：非质押者取回 revert
    function test_Unstake_RevertWhen_NotOwner() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 1); 

        skipDays(1);

        vm.prank(bob);
        vm.expectRevert("not owner");
        staking.unstake(stakeId);
    }

    /// @notice 边界：取回不存在的 stakeId 时 revert（先触发 owner 检查）
    function test_Unstake_RevertWhen_NoStake() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        staking.unstake(999);
    }

    /// @notice 边界：0天档（不锁仓）可以立即取回—
    function test_Unstake_NoLockTier_Immediate() public {
        vm.prank(alice);
        uint256 stakeId = staking.stake(100 ether, 0); // 0天档，不锁

        vm.prank(alice);
        staking.unstake(stakeId); // 立即可取

        assertEq(stakeToken.balanceOf(alice), 1_000_000 ether);
    }

    // ============================================================
    //                      查询（earned / getUserStakeIds）
    // ============================================================

    /// @notice 正常路径：earned 返回正确的可领取奖励（含锁仓倍率和凭证加成）
    function test_Earned_ReturnsCorrectAmount() public {
        vm.prank(alice);
        staking.stake(1000 ether, 1); // 30天档 1.2x

        skipDays(1);

        uint256 earned = staking.earned(alice);
        assertApproxEqAbs(earned, 333333 ether, 1000 ether);
    }

    /// @notice 正常路径：锁仓倍率生效——同本金同凭证，180天档(2.0x)奖励是0天档(1.0x)的2倍
    function test_LockMultiplier_Applies() public {
        vm.prank(alice);
        staking.stake(1000 ether, 0); // 0天档 1.0x
        vm.prank(bob);
        staking.stake(1000 ether, 3); // 180天档 2.0x

        skipDays(1);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);

        assertApproxEqAbs(bobEarned, aliceEarned * 2, aliceEarned / 1000);
    }

    /// @notice 正常路径：getUserStakeIds 返回用户所有质押 id
    function test_GetUserStakeIds_ReturnsAll() public {
        vm.prank(alice);
        uint256 id1 = staking.stake(100 ether, 1); // 30天档
        vm.prank(alice);
        uint256 id2 = staking.stake(200 ether, 3); // 180天档

        uint256[] memory ids = staking.getUserStakeIds(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
    }

    // ============================================================
    //                      周期机制
    // ============================================================

    /// @notice 正常路径：周期结束后奖励停止增长
    function test_RewardStopsAfterPeriod() public {
        vm.prank(alice);
        staking.stake(1000 ether, 1); // 30天档

        skipDays(30);
        uint256 earnedAt30 = staking.earned(alice);

        skipDays(10);
        uint256 earnedAt40 = staking.earned(alice);

        assertEq(earnedAt40, earnedAt30);
    }

    /// @notice 正常路径：奖励速率正确（已按 boostMultiplier 折算）
    function test_RewardRate_Correct() public view {
        uint256 boost = staking.boostMultiplier();
        uint256 expectedRate = (10_000_000 ether * 1e18) / (30 days * boost);
        assertEq(staking.rewardRate(), expectedRate);
    }

    /// @notice 边界：注入奖励后无人质押（空池），首笔质押不 revert，earned 正常累积
    function test_Stake_AfterEmptyPool_Works() public {
        // BaseTest 已注入 INITIAL_REWARD，此时 totalStaked == 0（空池）
        assertEq(staking.totalStaked(), 0);

        vm.prank(alice);
        staking.stake(1000 ether, 1); // 空池期后首笔质押不 revert

        assertEq(staking.totalStaked(), 1200 ether);

        skipDays(1);
        assertGt(staking.earned(alice), 0); // 从质押时刻起正常累积
    }

    /// @notice 不变量：全周期结束，累计发放 ≤ 注入预算（全员持证的最坏情况也不超发）
    function test_TotalPayout_NeverExceedsBudget() public {
        // 全员持证：三人都质押在早期窗口内，自动获得凭证（1.2x 加成全开）
        vm.prank(alice);
        staking.stake(1000 ether, 3);
        vm.prank(bob);
        staking.stake(1000 ether, 3);
        vm.prank(carol);
        staking.stake(1000 ether, 3);

        skipDays(31); // 周期结束

        vm.prank(alice);
        staking.getReward();
        vm.prank(bob);
        staking.getReward();
        vm.prank(carol);
        staking.getReward();

        uint256 paid = INITIAL_REWARD - rewardToken.balanceOf(address(staking));
        assertLe(paid, INITIAL_REWARD); // 核心不变量：不超发
        assertApproxEqAbs(paid, INITIAL_REWARD, INITIAL_REWARD / 1000); // 最坏情况接近满预算
    }
}
