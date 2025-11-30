// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../interfaces/IL2RewardManager.sol";


abstract contract L2RewardManagerStorage is IL2RewardManager {
    mapping(address => uint256) public stakerRewards;
    mapping(address => uint256) public operatorRewards;

    // 添加映射跟踪已申领金额
    mapping(address => mapping(address => uint256)) public claimedStakerRewards;  // strategy => staker => claimed
}