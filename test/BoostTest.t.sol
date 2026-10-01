// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./base/BaseTest.t.sol";
import {BoostCredential} from "../src/BoostCredential.sol";

contract BoostTest is BaseTest {
    /// @notice 正常路径：早期窗口内质押自动获得凭证且只有一张
    function test_EarlyStake_MintsCredential() public {
        vm.prank(alice);
        staking.stake(100 ether, 1);
        vm.prank(alice);
        staking.stake(200 ether, 3);

        assertTrue(boostCredential.hasMinted(alice));
        assertTrue(boostCredential.userHasBoost(alice));
        assertEq(boostCredential.balanceOf(alice, 0), 1);
    }

    /// @notice 正常路径：同本金同档位，有凭证的用户奖励是无凭证的 1.2 倍
    function test_CredentialBoostsReward() public {
        // alice 在早期窗口内质押 → 自动获得凭证
        vm.prank(alice);
        staking.stake(1000 ether, 3); // 180天档 2.0x

        // 先领掉 alice 前期 solo 奖励，把 rewardDebt 对齐到当前 rpt
        vm.prank(alice);
        staking.getReward();

        // 跳过早期窗口（7天），alice 再领一次，把 7 天 solo 积累清空
        skipDays(8);
        vm.prank(alice);
        staking.getReward();

        // bob 在窗口外质押 → 无凭证，同本金同档位
        vm.prank(bob);
        staking.stake(1000 ether, 3); // 180天档 2.0x

        skipDays(1);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);

        // 两人锁仓倍率相同、起点已对齐，alice 多 1.2x 凭证加成 → 比例精确 1.2:1
        assertApproxEqAbs(aliceEarned, (bobEarned * 12) / 10, bobEarned / 1000);
    }

    /// @notice 正常路径：凭证可转让
    function test_CredentialTransferable() public {
        vm.prank(alice);
        staking.stake(100 ether, 1); // alice 获得凭证

        assertTrue(boostCredential.userHasBoost(alice));
        assertFalse(boostCredential.userHasBoost(bob));

        // alice 把凭证转给 bob
        vm.prank(alice);
        boostCredential.safeTransferFrom(alice, bob, 0, 1, "");

        assertFalse(boostCredential.userHasBoost(alice));
        assertTrue(boostCredential.userHasBoost(bob));
    }

    /// @notice 边界：早期窗口结束后质押不获得凭证
    function test_AfterDeadline_NoCredential() public {
        skipDays(8); // 过了 7 天窗口

        vm.prank(alice);
        staking.stake(100 ether, 2); // 90天档

        assertFalse(boostCredential.hasMinted(alice));
        assertFalse(boostCredential.userHasBoost(alice));
    }

    /// @notice 边界：非 owner 调用 mintBoostCredential revert
    function test_MintBoostCredential_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        boostCredential.mintBoostCredential(alice);
    }

    /// @notice 边界：重复铸造同一地址 revert
    function test_MintBoostCredential_RevertWhen_AlreadyMinted() public {
        vm.prank(address(staking));
        boostCredential.mintBoostCredential(alice);

        vm.prank(address(staking));
        vm.expectRevert("Already minted");
        boostCredential.mintBoostCredential(alice);
    }

    /// @notice 正常路径：凭证铸造后 balanceOf （ERC1155凭证数量）正确
    function test_MintBoostCredential_BalanceCorrect() public {
        vm.prank(address(staking));
        boostCredential.mintBoostCredential(alice);

        assertEq(boostCredential.balanceOf(alice, 0), 1);
        assertTrue(boostCredential.hasMinted(alice));
    }

}
