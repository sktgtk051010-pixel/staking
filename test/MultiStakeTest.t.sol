// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./base/BaseTest.t.sol";

contract MultiStakeTest is BaseTest {
    /// @notice 正常路径：同一用户创建多笔不同档位，档位参数各自正确写入
    function test_MultipleStakes_DifferentTiers() public {
        vm.prank(alice);
        uint256 id1 = staking.stake(100 ether, 1); // 30天 1.2x
        vm.prank(alice);
        uint256 id2 = staking.stake(200 ether, 3); // 180天 2.0x

        (, , uint256 unlock1, uint256 mult1) = staking.stakes(id1);
        (, , uint256 unlock2, uint256 mult2) = staking.stakes(id2);

        assertEq(unlock1, block.timestamp + 30 days);
        assertEq(mult1, 1.2e18);
        assertEq(unlock2, block.timestamp + 180 days);
        assertEq(mult2, 2e18);
    }

    /// @notice 正常路径：多笔解锁时间独立；取回一笔不影响另一笔；id自增
    function test_MultipleStakes_IndependentUnlock() public {
        vm.prank(bob);
        staking.stake(5000 ether, 0);

        vm.prank(alice);
        uint256 id1 = staking.stake(100 ether, 1); // 30天
        vm.prank(alice);
        uint256 id2 = staking.stake(200 ether, 2); // 90天

        skipDays(30);
        vm.prank(alice);
        staking.unstake(id1);

        vm.prank(alice);
        vm.expectRevert("still locked");
        staking.unstake(id2);

        (uint256 amount2, , , ) = staking.stakes(id2);
        assertEq(amount2, 200 ether);
        assertEq(staking.totalStaked(), 5200 ether); 
        uint256[] memory ids = staking.getUserStakeIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], id2);

        vm.prank(alice);
        uint256 id3 = staking.stake(100 ether, 2); 

        assertEq(id3, 4); 
    }

    /// @notice 边界：用户没有质押时 getUserStakeIds 返回空数组
    function test_GetUserStakeIds_Empty() public view {
        uint256[] memory ids = staking.getUserStakeIds(alice);
        assertEq(ids.length, 0);
    }

    /// @notice 正常路径：多用户多笔质押，totalStaked 正确
    function test_MultipleUsers_MultipleStakes() public {
        vm.prank(alice);
        staking.stake(100 ether, 1); 
        vm.prank(alice);
        staking.stake(200 ether, 3); 
        vm.prank(bob);
        staking.stake(300 ether, 2); 

        assertEq(staking.totalStaked(), 600 ether);
        assertEq(staking.getUserStakeIds(alice).length, 2);
        assertEq(staking.getUserStakeIds(bob).length, 1);
    }
}
