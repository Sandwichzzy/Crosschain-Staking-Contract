// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IDelegationManager.sol";

/**
 * @title DelegationManagerStorage
 * @notice 委托管理器的存储合约，包含所有状态变量和存储布局
 * @dev 这是一个抽象合约，用于管理质押者与操作员之间的委托关系
 */
abstract contract DelegationManagerStorage is IDelegationManager {
    /// @notice EIP712 域分隔符的类型哈希，用于签名验证
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice 质押者委托的类型哈希，用于验证质押者的委托签名
    bytes32 public constant STAKER_DELEGATION_TYPEHASH =
        keccak256("StakerDelegation(address staker,address operator,uint256 nonce,uint256 expiry)");

    /// @notice 委托批准的类型哈希，用于验证操作员批准者的签名
    bytes32 public constant DELEGATION_APPROVAL_TYPEHASH = keccak256(
        "DelegationApproval(address staker,address operator,address delegationApprover,bytes32 salt,uint256 expiry)"
    );

    /// @notice EIP712 域分隔符，用于防止跨链重放攻击
    bytes32 internal _DOMAIN_SEPARATOR;

    /// @notice 最大提款延迟区块数（约30天，假设每12秒一个区块）
    uint256 public constant MAX_WITHDRAWAL_DELAY_BLOCKS = 216000;

    /// @notice 记录每个操作员在每个策略中持有的份额总数
    /// @dev 映射: 操作员地址 => 策略合约 => 份额数量
    mapping(address => mapping(address => uint256)) public operatorShares;

    /// @notice 记录每个操作员在每个策略中通过持有对应的质押者的份额数量 （需要确认）
    /// @dev 映射: 操作员地址=> 策略合约=> 对应的质押者=>份额数量
    mapping(address => mapping(address => mapping(address => uint256))) public stakerStrategyOperatorShares;

    /// @notice 存储每个操作员的详细信息（收益接收者、批准者、选择退出窗口期）
    mapping(address => OperatorDetails) internal _operatorDetails;

    /// @notice 记录每个质押者当前委托给哪个操作员
    /// @dev 映射: 质押者地址 => 操作员地址
    mapping(address => address) public delegatedTo;

    /// @notice 每个质押者的随机数，用于防止签名重放攻击
    mapping(address => uint256) public stakerNonce;

    /// @notice 记录委托批准者的盐值是否已被使用，防止重复使用
    /// @dev 映射: 批准者地址 => 盐值 => 是否已使用
    mapping(address => mapping(bytes32 => bool)) public delegationApproverSaltIsSpent;

    /// @notice 最小提款延迟区块数，所有策略的最低延迟时间
    uint256 public minWithdrawalDelayBlocks;

    /// @notice 记录待处理的提款请求（通过提款根哈希标识）
    /// @dev 映射: 提款根哈希 => 是否存在
    mapping(bytes32 => bool) public pendingWithdrawals;

    /// @notice 记录每个质押者累计排队的提款次数
    mapping(address => uint256) public cumulativeWithdrawalsQueued;

    /// @notice 每个策略的提款延迟区块数
    /// @dev 映射: 策略合约 => 延迟区块数
    mapping(address => uint256) public strategyWithdrawalDelayBlocks;

    /// @notice 存储间隙，为未来升级预留39个存储槽位
    uint256[39] private __gap;
}
