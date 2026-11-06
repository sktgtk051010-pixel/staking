// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./base/BaseTest.t.sol";
import {BoostCredential} from "../src/BoostCredential.sol";
import {TimeBoostStaking} from "../src/TimeBoostStaking.sol";
import {StakeToken} from "../src/StakeToken.sol";

/// @notice 普通合约钱包：部署后由外部调用 stake
contract ContractWalletStaker {
    function stakeOn(TimeBoostStaking staking, StakeToken stakeToken, uint256 amount) external {
        stakeToken.approve(address(staking), amount);
        staking.stake(amount, 0);
    }
}

/// @notice 构造函数内直接调用 stake
contract ConstructorStaker {
    constructor(TimeBoostStaking staking, StakeToken stakeToken, uint256 amount) {
        stakeToken.approve(address(staking), amount);
        staking.stake(amount, 0);
    }
}

contract BoostTest is BaseTest {
    /// @notice 正常路径：早期窗口内 EOA 达标质押自动获得凭证且只有一张
    function test_EarlyStake_MintsCredential() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 1); // 达标门槛 1000 ST
        vm.prank(alice, alice);
        staking.stake(200 ether, 3);

        assertTrue(boostCredential.hasMinted(alice));
        assertTrue(boostCredential.userHasBoost(alice));
        assertEq(boostCredential.balanceOf(alice, 0), 1);
    }

    /// @notice 正常路径：同本金同档位，有凭证的用户奖励是无凭证的 1.2 倍
    function test_CredentialBoostsReward() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 3);

        vm.prank(alice);
        staking.getReward();

        skipDays(8);
        vm.prank(alice);
        staking.getReward();

        vm.prank(bob);
        staking.stake(1000 ether, 3); // 180天档 2.0x

        skipDays(1);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);

        assertApproxEqAbs(aliceEarned, (bobEarned * 12) / 10, bobEarned / 1000);
    }

    /// @notice 正常路径：凭证可转让
    function test_CredentialTransferable() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 1);

        assertTrue(boostCredential.userHasBoost(alice));
        assertFalse(boostCredential.userHasBoost(bob));

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

    /// @notice 早期窗口内：普通合约钱包（非构造期）质押不自动获得凭证
    function test_ContractWallet_Stake_MintsCredential() public {
        ContractWalletStaker wallet = new ContractWalletStaker();
        stakeToken.mint(address(wallet), 1000 ether);

        wallet.stakeOn(staking, stakeToken, 1000 ether);

        assertFalse(boostCredential.hasMinted(address(wallet)));
        assertFalse(boostCredential.userHasBoost(address(wallet)));
        assertEq(boostCredential.balanceOf(address(wallet), 0), 0);
    }

    /// @notice 早期窗口内：合约在自身构造函数内调用 stake() 不获得凭证
    function test_ConstructorStake_MintsCredential() public {
        bytes32 salt = keccak256("constructor_staker_salt");
        bytes32 codeHash = keccak256(
            abi.encodePacked(type(ConstructorStaker).creationCode, abi.encode(staking, stakeToken, 1000 ether))
        );
        address predicted = vm.computeCreate2Address(salt, codeHash, address(this));

        stakeToken.mint(predicted, 1000 ether);
        ConstructorStaker wallet = new ConstructorStaker{salt: salt}(staking, stakeToken, 1000 ether);

        assertEq(address(wallet), predicted);
        assertFalse(boostCredential.hasMinted(address(wallet)));
        assertFalse(boostCredential.userHasBoost(address(wallet)));
        assertEq(boostCredential.balanceOf(address(wallet), 0), 0);
    }

    /// @notice 早期窗口内 EOA 质押不足 1000 ST 不获得凭证
    function test_LowAmount_NoCredential() public {
        vm.prank(alice, alice);
        staking.stake(999 ether, 1);

        assertFalse(boostCredential.hasMinted(alice));
        assertFalse(boostCredential.userHasBoost(alice));
    }

    /// @notice 周期结束后反复调倍率：同切点覆盖末页，段表不增长
    function test_SetBoostMultiplier_RepeatedAfterEnd_CoversLastPage() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 1);

        skipDays(31);
        assertEq(staking.boostPageCount(), 1);

        staking.setBoostMultiplier(1.5e18);
        assertEq(staking.boostPageCount(), 2);
        assertEq(staking.cutBoost(1), 1.5e18);

        uint256 cutPoint = staking.cutRpt(1);

        staking.setBoostMultiplier(1.0e18);
        staking.setBoostMultiplier(1.8e18);
        staking.setBoostMultiplier(1.2e18);

        assertEq(staking.boostPageCount(), 2);
        assertEq(staking.cutRpt(1), cutPoint);
        assertEq(staking.cutBoost(1), 1.2e18);
    }

    /// @notice 周期结束后调整/覆盖倍率不影响已产生的历史奖励
    function test_SetBoostMultiplier_CoverKeepsHistoricalRewards() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 1);

        skipDays(31);
        uint256 earnedBefore = staking.earned(alice);
        assertApproxEqRel(earnedBefore, 10_000_000 ether, 1e6);

        staking.setBoostMultiplier(1.5e18);
        assertEq(staking.earned(alice), earnedBefore);

        staking.setBoostMultiplier(1.0e18);
        assertEq(staking.earned(alice), earnedBefore);
        assertEq(staking.boostPageCount(), 2);
    }

    /// @notice 注入新周期后 rpT 前进 → 追加新页，跨周期按各页倍率分段结算
    function test_SetBoostMultiplier_NewPeriod_PushesNewPage() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 1);

        skipDays(31);
        staking.setBoostMultiplier(1.5e18);
        staking.setBoostMultiplier(1.0e18);
        assertEq(staking.boostPageCount(), 2);

        rewardToken.mint(owner, 5_000_000 ether);
        rewardToken.approve(address(staking), 5_000_000 ether);
        staking.notifyRewardAmount(5_000_000 ether);
        skipDays(31);
        staking.setBoostMultiplier(2e18);

        assertEq(staking.boostPageCount(), 3);
        assertEq(staking.cutBoost(0), 1.2e18);
        assertEq(staking.cutBoost(1), 1e18);
        assertEq(staking.cutBoost(2), 2e18);
        assertApproxEqRel(staking.earned(alice), 15_000_000 ether, 1e6);
    }

    /// @notice 边界：未结算就转让凭证，转让前区间的加成按新持有者判定而作废
    function test_CredentialTransfer_UnsettledBoostLost() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 0);

        skipDays(10);
        uint256 rpt10 = (10 days * staking.rewardRate() * 1e18) / staking.totalStaked();
        uint256 boosted10 = ((1000 ether * rpt10) / 1e18 * 12) / 10;

        // 未调用 getReward 即转让
        vm.prank(alice);
        boostCredential.safeTransferFrom(alice, bob, 0, 1, "");

        skipDays(5);
        uint256 rpt5 = (5 days * staking.rewardRate() * 1e18) / staking.totalStaked();
        uint256 rpt15 = (15 days * staking.rewardRate() * 1e18) / staking.totalStaked();
        uint256 ideal = boosted10 + (1000 ether * rpt5) / 1e18;
        uint256 actual = staking.earned(alice);

        assertLt(actual, ideal, "unsettled boost lost");
        assertApproxEqAbs(actual, (1000 ether * rpt15) / 1e18, 3, "all 15d unboosted");
    }

    /// @notice 边界：先结算再转让，已落袋的加成不受影响，后续按无加成累计
    function test_CredentialTransfer_AfterSettle_NoLoss() public {
        vm.prank(alice, alice);
        staking.stake(1000 ether, 0);

        skipDays(10);
        uint256 rpt10 = (10 days * staking.rewardRate() * 1e18) / staking.totalStaked();

        uint256 before = rewardToken.balanceOf(alice);
        vm.prank(alice);
        staking.getReward();
        uint256 got = rewardToken.balanceOf(alice) - before;
        assertApproxEqAbs(got, ((1000 ether * rpt10) / 1e18 * 12) / 10, 3, "settled at 1.2x");

        vm.prank(alice);
        boostCredential.safeTransferFrom(alice, bob, 0, 1, "");

        skipDays(5);
        uint256 rpt5 = (5 days * staking.rewardRate() * 1e18) / staking.totalStaked();
        assertApproxEqAbs(staking.earned(alice), (1000 ether * rpt5) / 1e18, 3, "5d unboosted");
    }
}
