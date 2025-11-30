// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-upgrades/contracts/access/AccessControlUpgradeable.sol";

import "../../interfaces/IMessageManager.sol";

/// @title MessageManager - 跨链消息管理合约
/// @notice 管理跨链消息的发送和认领,确保消息的唯一性和可追踪性
/// @dev 使用消息哈希来防止重放攻击,通过 nonce 保证消息唯一性
contract MessageManager is
    Initializable,
    ReentrancyGuard,
    AccessControlUpgradeable,
    IMessageManager
{
    /// @notice 下一个消息的序号,从 1 开始递增
    uint256 public nextMessageNumber;

    /// @notice PoolManager(桥接合约)的地址,只有它可以发送和认领消息
    address public poolManagerAddress;

    /// @notice 记录已发送的消息状态,键为消息哈希,值为是否已发送
    mapping(bytes32 => bool) public sentMessageStatus;

    /// @notice 记录已认领的消息状态,键为消息哈希,值为是否已认领
    mapping(bytes32 => bool) public claimMessageStatus;

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化 MessageManager 合约
    /// @param _poolManagerAddress PoolManager 合约地址
    function initialize(address _poolManagerAddress) public initializer {
        poolManagerAddress = _poolManagerAddress;
        nextMessageNumber = 1;
    }

    /// @notice 只允许 PoolManager 调用的修饰符
    modifier onlyTokenBridge() {
        require(
            msg.sender == poolManagerAddress,
            "MessageManager: only token bridge can do this operate"
        );
        _;
    }

    /// @notice 发送跨链消息
    /// @dev 生成消息哈希并记录,Relayer 会监听 MessageSent 事件来中继消息
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    /// @param _to 目标链上的接收地址
    /// @param _value 转账金额(已扣除手续费)
    /// @param _fee 手续费金额
    function sendMessage(
        uint256 sourceChainId,
        uint256 destChainId,
        address _to,
        uint256 _value,
        uint256 _fee
    ) external onlyTokenBridge {
        if (_to == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        uint256 messageNumber = nextMessageNumber;
        bytes32 messageHash = keccak256(
            abi.encode(
                sourceChainId,
                destChainId,
                _to,
                _fee,
                _value,
                messageNumber
            )
        );
        nextMessageNumber++;
        sentMessageStatus[messageHash] = true;
        emit MessageSent(
            sourceChainId,
            destChainId,
            msg.sender,
            _to,
            _fee,
            _value,
            messageNumber,
            messageHash
        );
    }

    /// @notice 认领跨链消息
    /// @dev 在目标链上由 Relayer 调用,验证消息的合法性并标记为已认领
    /// @dev 防止重入攻击,防止同一消息被认领多次
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    /// @param _to 接收地址
    /// @param _fee 手续费金额
    /// @param _value 转账金额
    /// @param _nonce 消息序号,用于生成唯一的消息哈希
    function claimMessage(
        uint256 sourceChainId,
        uint256 destChainId,
        address _to,
        uint256 _fee,
        uint256 _value,
        uint256 _nonce
    ) external onlyTokenBridge nonReentrant {
        // 生成与源链相同的消息哈希
        bytes32 messageHash = keccak256(
            abi.encode(sourceChainId, destChainId, _to, _fee, _value, _nonce)
        );
        // 标记消息已认领,防止重放攻击
        claimMessageStatus[messageHash] = true;
        emit MessageClaimed(sourceChainId, destChainId, messageHash);
    }


}