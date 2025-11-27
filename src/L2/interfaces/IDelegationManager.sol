// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureUtils} from "./ISignatureUtils.sol";

interface IDelegationManager is ISignatureUtils {
    enum OperatorType {
        SocialNode,
        GameNode,
        MpcNode,
        DaNode,
        TradingNode,
        AiNode,
        otherNode
    }

    /**
     * @notice 操作员详细信息结构体
     * @param earningsReceiver 收益接收者地址，接收该操作员的所有奖励
     * @param delegationApprover 委托批准者地址，可以批准或拒绝委托请求（零地址表示自动批准）
     * @param stakerOptOutWindowBlocks 质押者选择退出窗口期（区块数），质押者在此期间内不能取消委托
     */
    struct OperatorDetails {
        address earningsReceiver;
        address delegationApprover;
        uint32 stakerOptOutWindowBlocks;
        OperatorType operatorType;
    }

    /**
     * @notice 质押者委托结构体，用于签名委托
     * @param staker 质押者地址
     * @param operator 操作员地址
     * @param nonce 随机数，防止签名重放
     * @param expiry 签名过期时间戳
     */
    struct StakerDelegation {
        address staker;
        address operator;
        uint256 nonce;
        uint256 expiry;
    }

    /**
     * @notice 委托批准结构体，用于操作员批准者签名
     * @param staker 质押者地址
     * @param operator 操作员地址
     * @param salt 盐值，用于唯一标识此批准，防止重放
     * @param expiry 批准过期时间戳
     */
    struct DelegationApproval {
        address staker;
        address operator;
        bytes32 salt;
        uint256 expiry;
    }

    /**
     * @notice 提款结构体，包含提款的所有必要信息
     * @param staker 质押者地址
     * @param delegatedTo 提款时委托的操作员地址
     * @param withdrawer 提款接收者地址（可以与质押者不同）
     * @param nonce 提款交易的随机数
     * @param startBlock 提款开始的区块号
     * @param strategies 涉及的策略列表
     * @param shares 每个策略对应的份额数量
     */
    struct Withdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        address[] strategies;
        uint256[] shares;
    }

    /**
     * @notice 排队提款参数结构体
     * @param strategies 要提款的策略列表
     * @param shares 每个策略对应的份额数量
     * @param withdrawer 提款接收者地址
     */
    struct QueuedWithdrawalParams {
        address[] strategies;
        uint256[] shares;
        address withdrawer;
    }

    /// @notice 当新操作员注册时触发
    /// @param operator 操作员地址
    /// @param operatorDetails 操作员的详细信息
    event OperatorRegistered(address indexed operator, OperatorDetails operatorDetails);

    /// @notice 当操作员修改其详细信息时触发
    /// @param operator 操作员地址
    /// @param newOperatorDetails 更新后的操作员详细信息
    event OperatorDetailsModified(address indexed operator, OperatorDetails newOperatorDetails);

    /// @notice 当操作员更新其元数据URL时触发
    /// @param operator 操作员地址
    /// @param metadataURI 新的元数据URI
    event OperatorNodeUrlUpdated(address indexed operator, string metadataURI);

    /// @notice 当操作员的份额增加时触发（通常是质押者委托时）
    /// @param operator 操作员地址
    /// @param staker 质押者地址
    /// @param strategy 策略合约
    /// @param shares 增加的份额数量
    event OperatorSharesIncreased(address indexed operator, address staker, address strategy, uint256 shares);

    /// @notice 当操作员的份额减少时触发（通常是质押者取消委托时）
    /// @param operator 操作员地址
    /// @param staker 质押者地址
    /// @param strategy 策略合约
    /// @param shares 减少的份额数量
    event OperatorSharesDecreased(address indexed operator, address staker, address strategy, uint256 shares);

    /// @notice 当质押者委托给操作员时触发
    /// @param staker 质押者地址
    /// @param operator 操作员地址
    event StakerDelegated(address indexed staker, address indexed operator);

    /// @notice 当质押者取消委托时触发
    /// @param staker 质押者地址
    /// @param operator 操作员地址
    event StakerUndelegated(address indexed staker, address indexed operator);

    /// @notice 当质押者被强制取消委托时触发
    /// @param staker 质押者地址
    /// @param operator 操作员地址
    event StakerForceUndelegated(address indexed staker, address indexed operator);

    /// @notice 当提款请求被排队时触发
    /// @param withdrawalRoot 提款的根哈希
    /// @param withdrawal 提款详细信息
    event WithdrawalQueued(bytes32 withdrawalRoot, Withdrawal withdrawal);

    /// @notice 当提款完成时触发
    /// @param operator 操作员地址
    /// @param staker 质押者地址
    /// @param strategy 策略合约
    /// @param shares 提款的份额数量
    event WithdrawalCompleted(address operator, address staker, address strategy, uint256 shares);

    /// @notice 当最小提款延迟区块数被设置时触发
    /// @param previousValue 之前的值
    /// @param newValue 新的值
    event MinWithdrawalDelayBlocksSet(uint256 previousValue, uint256 newValue);

    /// @notice 当特定策略的提款延迟区块数被设置时触发
    /// @param strategy 策略合约
    /// @param previousValue 之前的值
    /// @param newValue 新的值
    event StrategyWithdrawalDelayBlocksSet(address strategy, uint256 previousValue, uint256 newValue);

    /**
     * @notice 注册为操作员
     * @param registeringOperatorDetails 操作员的详细信息（收益接收者、批准者、选择退出窗口期）
     * @param metadataURI 操作员的元数据URI（通常指向包含操作员信息的JSON文件）
     */
    function registerAsOperator(OperatorDetails calldata registeringOperatorDetails, string calldata metadataURI)
        external;

    /**
     * @notice 修改操作员的详细信息（只能由操作员自己调用）
     * @param newOperatorDetails 新的操作员详细信息
     */
    function modifyOperatorDetails(OperatorDetails calldata newOperatorDetails) external;

    /**
     * @notice 更新操作员的节点URL/元数据URI
     * @param metadataURI 新的元数据URI
     */
    function updateOperatorNodeUrl(string calldata metadataURI) external;

    /**
     * @notice 质押者委托给操作员
     * @param operator 要委托的操作员地址
     * @param approverSignatureAndExpiry 批准者的签名和过期时间（如果操作员设置了批准者）
     * @param approverSalt 批准签名的盐值，用于防止重放攻击
     */
    function delegateTo(address operator, SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt)
        external;

    /**
     * @notice 通过签名代表质押者进行委托（允许第三方代表质押者委托）
     * @param staker 质押者地址
     * @param operator 操作员地址
     * @param stakerSignatureAndExpiry 质押者的签名和过期时间
     * @param approverSignatureAndExpiry 批准者的签名和过期时间
     * @param approverSalt 批准签名的盐值
     */
    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external;

    /**
     * @notice 取消质押者的委托（可以由质押者或操作员调用）
     * @param staker 要取消委托的质押者地址
     * @return withdrawalRoot 返回提款根哈希数组
     */
    function undelegate(address staker) external returns (bytes32[] memory withdrawalRoot);

    /**
     * @notice 排队一个或多个提款请求
     * @param queuedWithdrawalParams 提款参数数组（策略、份额、接收者）
     * @return 返回提款根哈希数组
     */
    function queueWithdrawals(QueuedWithdrawalParams[] calldata queuedWithdrawalParams)
        external
        returns (bytes32[] memory);

    /**
     * @notice 完成单个排队的提款
     * @param withdrawal 提款详细信息
     * @param weth代币合约地址
     * @param middlewareTimesIndex 中间件时间索引
     * @param receiveAsTokens 是否以代币形式接收
     */
    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        IERC20 weth,
        uint256 middlewareTimesIndex,
        bool receiveAsTokens
    ) external;

    /**
     * @notice 完成多个排队的提款
     * @param withdrawals 提款详细信息数组
     * @param weth代币合约地址
     * @param middlewareTimesIndexes 中间件时间索引数组
     * @param receiveAsTokens 是否以代币形式接收的布尔数组
     */
    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        IERC20 weth,
        uint256[] calldata middlewareTimesIndexes,
        bool[] calldata receiveAsTokens
    ) external;

    /**
     * @notice 增加质押者委托给操作员的份额（只能由策略管理器调用）
     * @param staker 质押者地址
     * @param strategy 策略合约
     * @param shares 要增加的份额数量
     */
    function increaseDelegatedShares(address staker, address strategy, uint256 shares) external;

    /**
     * @notice 减少质押者委托给操作员的份额（只能由策略管理器调用）
     * @param staker 质押者地址
     * @param strategy 策略合约
     * @param shares 要减少的份额数量
     */
    function decreaseDelegatedShares(address staker, address strategy, uint256 shares) external;

    /**
     * @notice 查询质押者当前委托给哪个操作员
     * @param staker 质押者地址
     * @return 操作员地址（如果未委托则返回零地址）
     */
    function delegatedTo(address staker) external view returns (address);

    /**
     * @notice 获取操作员的详细信息
     * @param operator 操作员地址
     * @return 操作员详细信息结构体
     */
    function operatorDetails(address operator) external view returns (OperatorDetails memory);

    /**
     * @notice 获取操作员的收益接收者地址
     * @param operator 操作员地址
     * @return 收益接收者地址
     */
    function earningsReceiver(address operator) external view returns (address);

    /**
     * @notice 获取操作员的委托批准者地址
     * @param operator 操作员地址
     * @return 委托批准者地址
     */
    function delegationApprover(address operator) external view returns (address);

    /**
     * @notice 获取操作员的质押者选择退出窗口期（区块数）
     * @param operator 操作员地址
     * @return 选择退出窗口期区块数
     */
    function stakerOptOutWindowBlocks(address operator) external view returns (uint256);

    /**
     * @notice 获取操作员在多个策略中的份额
     * @param operator 操作员地址
     * @param strategies 策略合约数组
     * @return 每个策略对应的份额数量数组
     */
    function getOperatorShares(address operator, address[] memory strategies) external view returns (uint256[] memory);

    /**
     * @notice 获取指定策略列表的最大提款延迟时间
     * @param strategies 策略合约数组
     * @return 最大延迟区块数
     */
    function getWithdrawalDelay(address[] calldata strategies) external view returns (uint256);

    /**
     * @notice 获取操作员在特定策略中的份额
     * @param operator 操作员地址
     * @param strategy 策略合约
     * @return 份额数量
     */
    function operatorShares(address operator, address strategy) external view returns (uint256);

    /**
     * @notice 检查质押者是否已委托给某个操作员
     * @param staker 质押者地址
     * @return 如果已委托返回true，否则返回false
     */
    function isDelegated(address staker) external view returns (bool);

    /**
     * @notice 检查地址是否已注册为操作员
     * @param operator 要检查的地址
     * @return 如果是操作员返回true，否则返回false
     */
    function isOperator(address operator) external view returns (bool);

    /**
     * @notice 获取质押者的当前随机数（用于签名验证）
     * @param staker 质押者地址
     * @return 随机数
     */
    function stakerNonce(address staker) external view returns (uint256);

    /**
     * @notice 检查委托批准者的盐值是否已被使用
     * @param _delegationApprover 委托批准者地址
     * @param salt 盐值
     * @return 如果已使用返回true，否则返回false
     */
    function delegationApproverSaltIsSpent(address _delegationApprover, bytes32 salt) external view returns (bool);

    /**
     * @notice 获取最小提款延迟区块数
     * @return 最小延迟区块数
     */
    function minWithdrawalDelayBlocks() external view returns (uint256);

    /**
     * @notice 获取特定策略的提款延迟区块数
     * @param strategy 策略合约
     * @return 延迟区块数
     */
    function strategyWithdrawalDelayBlocks(address strategy) external view returns (uint256);

    /**
     * @notice 计算当前质押者委托的摘要哈希（用于签名验证）
     * @param staker 质押者地址
     * @param operator 操作员地址
     * @param expiry 过期时间戳
     * @return 摘要哈希
     */
    function calculateCurrentStakerDelegationDigestHash(address staker, address operator, uint256 expiry)
        external
        view
        returns (bytes32);

    /**
     * @notice 计算质押者委托的摘要哈希（指定随机数）
     * @param staker 质押者地址
     * @param _stakerNonce 质押者的随机数
     * @param operator 操作员地址
     * @param expiry 过期时间戳
     * @return 摘要哈希
     */
    function calculateStakerDelegationDigestHash(
        address staker,
        uint256 _stakerNonce,
        address operator,
        uint256 expiry
    ) external view returns (bytes32);

    /**
     * @notice 计算委托批准的摘要哈希
     * @param staker 质押者地址
     * @param operator 操作员地址
     * @param _delegationApprover 委托批准者地址
     * @param approverSalt 批准者盐值
     * @param expiry 过期时间戳
     * @return 摘要哈希
     */
    function calculateDelegationApprovalDigestHash(
        address staker,
        address operator,
        address _delegationApprover,
        bytes32 approverSalt,
        uint256 expiry
    ) external view returns (bytes32);

    /**
     * @notice 获取域类型哈希常量
     * @return 域类型哈希
     */
    function DOMAIN_TYPEHASH() external view returns (bytes32);

    /**
     * @notice 获取质押者委托类型哈希常量
     * @return 质押者委托类型哈希
     */
    function STAKER_DELEGATION_TYPEHASH() external view returns (bytes32);

    /**
     * @notice 获取委托批准类型哈希常量
     * @return 委托批准类型哈希
     */
    function DELEGATION_APPROVAL_TYPEHASH() external view returns (bytes32);

    /**
     * @notice 获取EIP712域分隔符
     * @return 域分隔符
     */
    function domainSeparator() external view returns (bytes32);

    /**
     * @notice 获取质押者累计排队的提款次数
     * @param staker 质押者地址
     * @return 累计提款次数
     */
    function cumulativeWithdrawalsQueued(address staker) external view returns (uint256);

    /**
     * @notice 计算提款的根哈希（用于唯一标识提款）
     * @param withdrawal 提款详细信息
     * @return 提款根哈希
     */
    function calculateWithdrawalRoot(Withdrawal memory withdrawal) external pure returns (bytes32);
}
