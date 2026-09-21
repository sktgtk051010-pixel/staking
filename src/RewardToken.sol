// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RewardToken
/// @notice 奖励代币（符号 RT）。部署后 owner 铸造一批，转给 Staking 合约作为奖励池。
contract RewardToken is ERC20, Ownable {
    constructor() ERC20("Reward Token", "RT") Ownable(msg.sender) {}

    /// @notice 铸造代币
    /// @param to 接收地址
    /// @param amount 铸造数量
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
