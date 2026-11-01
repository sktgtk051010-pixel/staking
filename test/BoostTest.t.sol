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
}
