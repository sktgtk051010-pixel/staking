// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BoostCredential
/// @notice 早期参与凭证（ERC1155）。项目早期质押的用户可获得一张，持有它在 Staking 中享受额外奖励加成。
/// @dev 凭证可转让（按当前持有者判定加成），一个地址最多持有一张。
contract BoostCredential is ERC1155, Ownable {
    
    uint256 public constant BOOST_TOKEN_ID = 0;

    mapping(address => bool) public hasMinted;

    event CredentialMinted(address indexed to, uint256 indexed tokenId);

    constructor() ERC1155("") Ownable(msg.sender) {}

    /// @notice 铸造一张增益凭证（每个地址最多一张）
    /// @param to 接收地址
    function mintBoostCredential(address to) external onlyOwner {
        require(!hasMinted[to], "Already minted");
        _mint(to, BOOST_TOKEN_ID, 1, "");
        hasMinted[to] = true;
        emit CredentialMinted(to, BOOST_TOKEN_ID);
    }

    /// @notice 查询地址是否持有增益凭证（用于 Staking 判定加成）
    /// @param user 待查询地址
    /// @return 持有返回 true
    function userHasBoost(address user) external view returns (bool) {
        return balanceOf(user, BOOST_TOKEN_ID) >= 1;
    }
}
