// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./base/BaseTest.t.sol";

contract AdminTest is BaseTest {
    // ============================================================
    //                   notifyRewardAmount
    // ============================================================

    /// @notice 正常路径：注入新周期奖励成功
    function test_NotifyRewardAmount_Success() public {
        skipDays(31);//跳过当前周期

        uint256 newReward = 50_000 ether;
        rewardToken.mint(owner, newReward);
        rewardToken.approve(address(staking), newReward);

        staking.notifyRewardAmount(newReward);

        uint256 boost = staking.boostMultiplier();
        uint256 expectedRate = (newReward * 1e18) / (30 days * boost);
        assertEq(staking.rewardRate(), expectedRate);
        assertEq(staking.periodFinish(), block.timestamp + 30 days);
        assertEq(staking.lastUpdateTime(), block.timestamp);
    }

    /// @notice 边界：非 owner 调用 revert
    function test_NotifyRewardAmount_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.notifyRewardAmount(100 ether);
    }

    /// @notice 正常路径：周期未结束时注入，剩余奖励并入新周期
    function test_NotifyRewardAmount_MidPeriod() public {
        skipDays(15); 

        uint256 newReward = 50_000 ether;
        rewardToken.mint(owner, newReward);
        rewardToken.approve(address(staking), newReward);

        staking.notifyRewardAmount(newReward);

        uint256 boost = staking.boostMultiplier();
        uint256 initialRate = (10_000_000 ether * 1e18) / (30 days * boost);
        uint256 remaining = (30 days - 15 days) * initialRate;
        uint256 expectedRate = ((remaining + newReward) * 1e18) / (30 days * boost);

        assertApproxEqAbs(staking.rewardRate(), expectedRate, 10);
        assertEq(staking.periodFinish(), block.timestamp + 30 days);
    }

    /// @notice 正常路径：周期中途注入后，新 rate 折算正确、earned 按新 rate 精确累积
    function test_NotifyRewardAmount_MidPeriod_EarnedAccrues() public {
        vm.prank(alice);
        staking.stake(1000 ether, 1); 

        skipDays(15);
        vm.prank(alice);
        staking.getReward(); 

        uint256 rateBefore = staking.rewardRate(); 
        uint256 newReward = 50_000 ether;
        rewardToken.mint(owner, newReward);
        rewardToken.approve(address(staking), newReward);
        staking.notifyRewardAmount(newReward);

        uint256 boost = staking.boostMultiplier();
        uint256 leftover = (30 days - 15 days) * rateBefore;
        uint256 expectedRate = ((leftover + newReward) * 1e18) / (30 days * boost);
        assertEq(staking.rewardRate(), expectedRate);

        skip(1 days);
        uint256 expectedIncrement = (1 days * expectedRate * boost) / 1e18;
        assertApproxEqAbs(staking.earned(alice), expectedIncrement, 1);
    }

    // ============================================================
    //                   setRewardsDuration
    // ============================================================

    /// @notice 正常路径：周期结束后设置周期长度
    function test_SetRewardsDuration_Success() public {
        skipDays(31); 
        staking.setRewardsDuration(60 days);
        assertEq(staking.rewardsDuration(), 60 days);
    }

    /// @notice 边界：非 owner 调用 revert
    function test_SetRewardsDuration_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setRewardsDuration(60 days);
    }

    /// @notice 边界：周期长度为 0 时 revert（防止除零）
    function test_SetRewardsDuration_RevertWhen_Zero() public {
        skipDays(31); 
        vm.expectRevert("duration too short");
        staking.setRewardsDuration(0);
    }

    /// @notice 边界：周期中间改长度 revert（必须等周期结束）
    function test_SetRewardsDuration_RevertWhen_PeriodNotFinished() public {
        skipDays(15); 
        vm.expectRevert("period not finished");
        staking.setRewardsDuration(60 days);
    }

    // ============================================================
    //                   setLockTier
    // ============================================================

    /// @notice 正常路径：修改档位参数
    function test_SetLockTier_Success() public {
        staking.setLockTier(1, 60 days, 1.5e18);

        (uint256 duration, uint256 multiplier) = staking.lockTiers(1);
        assertEq(duration, 60 days);
        assertEq(multiplier, 1.5e18);
    }

    /// @notice 边界：非 owner 调用 revert
    function test_SetLockTier_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setLockTier(1, 60 days, 1.5e18);
    }

    /// @notice 边界：锁仓倍率超过上限（5倍）时 revert
    function test_SetLockTier_RevertWhen_TooHigh() public {
        vm.expectRevert("multiplier too high");
        staking.setLockTier(1, 60 days, 6e18); // 6 倍 > 上限 5 倍
    }

    /// @notice 边界：档位下标越界时 revert
    function test_SetLockTier_RevertWhen_InvalidIndex() public {
        vm.expectRevert("bad tier");
        staking.setLockTier(99, 60 days, 1.5e18); // 不存在的档位
    }

    /// @notice 边界：锁仓时长为 0 时 revert（0 天档由 tier 0 承担）
    function test_SetLockTier_RevertWhen_ZeroDuration() public {
        vm.expectRevert("duration too short");
        staking.setLockTier(1, 0, 1.5e18);
    }

    /// @notice 边界：锁仓倍率低于 1.0x 时 revert（锁仓不该惩罚用户）
    function test_SetLockTier_RevertWhen_MultiplierTooLow() public {
        vm.expectRevert("multiplier too low");
        staking.setLockTier(1, 60 days, 0.5e18); // 0.5x < 下限 1.0x
    }

    // ============================================================
    //                   setBoostMultiplier
    // ============================================================

    /// @notice 正常路径：周期结束后修改凭证加成倍率
    function test_SetBoostMultiplier_Success() public {
        skipDays(31); // 周期结束后才可调整
        staking.setBoostMultiplier(1.5e18);
        assertEq(staking.boostMultiplier(), 1.5e18);
    }

    /// @notice 边界：非 owner 调用 revert
    function test_SetBoostMultiplier_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setBoostMultiplier(1.5e18);
    }

    /// @notice 边界：凭证加成超过上限（2倍）时 revert
    function test_SetBoostMultiplier_RevertWhen_TooHigh() public {
        skipDays(31); 
        vm.expectRevert("boost too high");
        staking.setBoostMultiplier(3e18); 
    }

    /// @notice 边界：周期未结束时调整凭证加成 revert
    function test_SetBoostMultiplier_RevertWhen_PeriodNotFinished() public {
        vm.expectRevert("period not finished");
        staking.setBoostMultiplier(1.5e18); 
    }

    // ============================================================
    //                   setEarlyMintDeadline
    // ============================================================

    /// @notice 正常路径：修改早期凭证截止时间
    function test_SetEarlyMintDeadline_Success() public {
        uint256 newDeadline = block.timestamp + 14 days;
        staking.setEarlyMintDeadline(newDeadline);
        assertEq(staking.earlyMintDeadline(), newDeadline);
    }

    /// @notice 边界：非 owner 调用 revert
    function test_SetEarlyMintDeadline_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setEarlyMintDeadline(block.timestamp + 14 days);
    }

    /// @notice 正常路径：延长截止时间后，新用户可获得凭证
    function test_SetEarlyMintDeadline_ExtendsWindow() public {
        skipDays(8);

        staking.setEarlyMintDeadline(block.timestamp + 7 days);

        vm.prank(alice);
        staking.stake(100 ether, 0);

        assertTrue(boostCredential.hasMinted(alice));
    }

    /// @notice 边界：截止时间设为过去时 revert
    function test_SetEarlyMintDeadline_RevertWhen_PastDeadline() public {
        vm.expectRevert("deadline in past");
        staking.setEarlyMintDeadline(0); 
    }

    /// @notice 端到端：周期结束→调boost→重新注入→全员持证满周期，支出恰好 = 新预算
    function test_FullCycle_BoostChange_Reinject_BudgetBalanced() public {
        vm.prank(alice);
        staking.stake(1000 ether, 3); 
        vm.prank(bob);
        staking.stake(1000 ether, 3);

        skipDays(31);
        vm.prank(alice);
        staking.getReward(); 
        vm.prank(bob);
        staking.getReward();

        staking.setBoostMultiplier(1.5e18); 

        uint256 newReward = 100_000 ether;
        rewardToken.mint(owner, newReward);
        rewardToken.approve(address(staking), newReward);
        staking.notifyRewardAmount(newReward); 
        assertEq(staking.rewardRate(), (newReward * 1e18) / (30 days * 1.5e18));

        skipDays(30);
        uint256 aliceBefore = rewardToken.balanceOf(alice);
        uint256 bobBefore = rewardToken.balanceOf(bob);
        vm.prank(alice);
        staking.getReward();
        vm.prank(bob);
        staking.getReward();
        uint256 alicePaid = rewardToken.balanceOf(alice) - aliceBefore;
        uint256 bobPaid = rewardToken.balanceOf(bob) - bobBefore;

        assertApproxEqAbs(alicePaid + bobPaid, newReward, newReward / 1000);
    }
}
