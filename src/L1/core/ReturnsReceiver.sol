// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {L1Base} from "./L1Base.sol";
import  "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

/// @title ReturnsReceiver 收益接收器
/// @notice 接收协议级别的收益并管理谁可以提取收益。在协议中部署为共识层提取钱包和执行层奖励钱包。
contract ReturnsReceiver is L1Base {
    /// @notice 管理员角色，负责管理 WITHDRAWER_ROLE。
    bytes32 public constant RECEIVER_MANAGER_ROLE = keccak256("RECEIVER_MANAGER_ROLE");

    /// @notice 提取者角色，可以从此合约中提取 ETH 和 ERC20 代币。
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    struct Init {
        address admin;
        address manager;
        address withdrawer;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(RECEIVER_MANAGER_ROLE, init.manager);
        _setRoleAdmin(WITHDRAWER_ROLE, RECEIVER_MANAGER_ROLE);
        _grantRole(WITHDRAWER_ROLE, init.withdrawer);
    }

    /// @notice 将指定数量的 ETH 转账到指定地址。
    /// @dev 仅由提取者调用。
    function transfer(address payable to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        Address.sendValue(to, amount);
    }

    /// @notice 将指定数量的 ERC20 代币转账到指定地址。
    /// @dev 仅由提取者调用。
    function transferERC20(IERC20 token, address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        SafeERC20.safeTransfer(token, to, amount);
    }

    receive() external payable {}
}