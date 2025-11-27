// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../interfaces/IStrategyManager.sol";
import "../interfaces/ISlashManager.sol";

abstract contract StrategyManagerStorage is IStrategyManager {

    /// @notice EIP712 域分隔符的类型哈希，用于签名验证
    bytes32 public constant DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice 存款的消息类型哈希，用于验证存款签名
    /// @dev 包含质押者、策略、weth代币、金额、随机数和过期时间
    bytes32 public constant DEPOSIT_TYPEHASH =
    keccak256("Deposit(address staker,address strategy,address weth,uint256 amount,uint256 nonce,uint256 expiry)");

    /// @notice 每个质押者可以使用的最大策略数量限制
    /// @dev 限制为32个策略，防止gas消耗过高 这里其实只用两种策略eth-strategy 和 weth-strategy
    uint8 internal constant MAX_STAKER_STRATEGY_LIST_LENGTH = 32;

    /// @notice EIP712 域分隔符，用于防止跨链签名重放攻击
    bytes32 internal _DOMAIN_SEPARATOR;

    /// @notice 每个地址的随机数，用于防止签名重放攻击
    /// @dev 映射: 地址 => 随机数
    mapping(address => uint256) public nonces;

    /// @notice 策略白名单管理员地址，有权添加/移除白名单策略
    address public strategyWhitelister;

    uint256 internal withdrawalDelayBlocks;

    /// @notice 记录每个质押者在每个策略中的份额数量
    /// @dev 映射: 质押者地址 => 策略合约 => 份额数量
    mapping(address => mapping(address => uint256)) public stakerStrategyShares;

    mapping(address => mapping(address => uint256)) public stakerStrategyL1BackShares;

    mapping(bytes32 => bool) public withdrawalRootPending;

    mapping(address => uint256) internal numWithdrawalsQueued;

    /// @notice 记录每个质押者参与的策略列表
    /// @dev 映射: 质押者地址 => 策略合约数组
    mapping(address => address[]) public stakerStrategyList;

    /// @notice 记录策略是否在存款白名单中
    /// @dev 只有白名单中的策略才能接受存款
    mapping(address => bool) public strategyIsWhitelistedForDeposit;

    /// @notice 信标链ETH份额递减映射（保留用于与信标链集成）
    /// @dev 映射: 地址 => 待递减的信标链ETH份额
    mapping(address => uint256) internal beaconChainETHSharesToDecrementOnWithdrawal;

    /// @notice 记录策略是否禁止第三方转账
    /// @dev 如果为true，则份额只能由所有者自己操作
    mapping(address => bool) public thirdPartyTransfersForbidden;

    /// @notice 存储间隙，为未来升级预留39个存储槽位
    uint256[39] private __gap;
}