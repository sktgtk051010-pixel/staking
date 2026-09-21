// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StakeToken
/// @notice 用户质押进 Staking 合约的本金代币（符号 ST）。部署后由 owner 铸造。
contract StakeToken is ERC20, Ownable {
    constructor() ERC20("Stake Token", "ST") Ownable(msg.sender) {}

    /// @notice 铸造代币
    /// @param to 接收地址
    /// @param amount 铸造数量
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
