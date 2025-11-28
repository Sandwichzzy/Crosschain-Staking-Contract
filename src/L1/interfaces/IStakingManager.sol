// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingManagerInitiationRead {
    /// @notice 发送到信标链存款合约的 ETH 总量。
    function totalDepositedInValidators() external view returns (uint256);
    /// @notice 由质押合约发起的验证者数量。
    function numInitiatedValidators() external view returns (uint256);
    /// @notice 质押合约初始化的区块号。
    function initializationBlockNumber() external view returns (uint256);
}

interface IStakingManagerReturnsWrite {
    /// @notice 接收收益聚合器发送的资金。
    function receiveReturns() external payable;
    /// @notice 接收解除质押请求管理器发送的资金。
    function receiveFromUnstakeRequestsManager() external payable;
}

interface IStakingManager is IStakingManagerInitiationRead, IStakingManagerReturnsWrite {
    error DoesNotReceiveETH();
    error InvalidConfiguration();
    error MaximumValidatorDepositExceeded();
    error MaximumDETHSupplyExceeded();
    error MinimumStakeBoundNotSatisfied();
    error MinimumDepositAmountNotSatisfied();
    error MinimumUnstakeBoundNotSatisfied();
    error MinimumValidatorDepositNotSatisfied();
    error NotEnoughDepositETH();
    error NotEnoughUnallocatedETH();
    error NotReturnsAggregator();
    error NotUnstakeRequestsManager();
    error NotDappLinkBridge();
    error Paused();
    // error ZeroAddress();
    error PreviouslyUsedValidator();
    error InvalidDepositRoot(bytes32);
    error UnstakeBelowMinimudETHAmount(uint256 ethAmount, uint256 expectedMinimum);

    error InvalidWithdrawalCredentialsWrongLength(uint256);
    error InvalidWithdrawalCredentialsNotETH1(bytes12);
    error InvalidWithdrawalCredentialsWrongAddress(address);

    /// @notice 当用户质押 ETH 并收到 dETH 时触发。
    /// @param staker 质押 ETH 的用户地址。
    /// @param ethAmount 质押的 ETH 数量。
    /// @param dETHAmount 收到的 dETH 数量。
    event Staked(address indexed staker, uint256 ethAmount, uint256 dETHAmount);

    event UnstakeLaveAmount(address indexed staker, uint256 dETHLocked);


    event UnstakeRequested(address indexed staker, address indexed l2Strategy, uint256 ethAmount, uint256 dETHLocked, uint256 destChainId, uint256 unStakeMessageNonce);


    event UnstakeRequestClaimed(address indexed staker, address[] indexed l2Strategys, address indexed bridge, uint256 sourceChainId, uint256 destChainId);

    /// @notice 当验证者已被发起时触发（即协议已存入存款合约）。
    /// @param id 验证者的 ID，即其公钥的哈希值。
    /// @param operatorID 验证者所属的节点运营商的 ID。
    /// @param pubkey 验证者的公钥。
    /// @param amountDeposited 为该验证者存入存款合约的 ETH 数量。
    event ValidatorInitiated(bytes32 indexed id, uint256 indexed operatorID, bytes pubkey, uint256 amountDeposited);

    /// @notice 当协议已将 ETH 分配给解除质押请求管理器时触发。
    /// @param amount 分配给解除质押请求管理器的 ETH 数量。
    event AllocatedETHToUnstakeRequestsManager(uint256 amount);

    /// @notice 当协议已将 ETH 分配用于存款合约的存款时触发。
    /// @param amount 分配给存款的 ETH 数量。
    event AllocatedETHToDeposits(uint256 amount);

    /// @notice 当协议已从收益聚合器收到收益时触发。
    /// @param amount 收到的 ETH 数量。
    event ReturnsReceived(uint256 amount);
}