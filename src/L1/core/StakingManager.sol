// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import  "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import  "../interfaces/IStakingManager.sol";
import { IDETH } from "../interfaces/IDETH.sol";
import { IOracleReadRecord, OracleRecord } from "../interfaces/IOracleManager.sol";
import {L1Base} from "./L1Base.sol";

import { IUnstakeRequestsManagerWrite } from "../interfaces/IUnstakeRequestsManager.sol";


contract StakingManager is L1Base, IStakingManager {
    /// @notice 允许触发管理任务的角色，例如向解除质押请求管理器分配资金 / 提取盈余，以及设置合约的各种参数。
    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");

    /// @notice 允许向解除质押请求管理器分配资金并预留资金以存入验证者的角色。
    bytes32 public constant ALLOCATOR_SERVICE_ROLE = keccak256("ALLOCATER_SERVICE_ROLE");

    /// @notice 允许通过将资金从 allocatedETHForDeposits 余额发送到信标链deposits合约来启动新验证者的角色。
    bytes32 public constant INITIATOR_SERVICE_ROLE = keccak256("INITIATOR_SERVICE_ROLE");

    /// @notice 管理质押白名单的角色。
    bytes32 public constant STAKING_ALLOWLIST_MANAGER_ROLE = keccak256("STAKING_ALLOWLIST_MANAGER_ROLE");

    /// @notice 当白名单启用时允许质押 ETH 的角色。
    bytes32 public constant STAKING_ALLOWLIST_ROLE = keccak256("STAKING_ALLOWLIST_ROLE");

    /// @notice 允许为协议中未分配的 ETH 充值的角色。
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    /// @notice 为验证者初始化提交的负载结构体。
    struct ValidatorParams {
        uint256 operatorID;
        uint256 depositAmount;
        bytes pubkey;
        bytes withdrawalCredentials;
        bytes signature;
        bytes32 depositDataRoot;
    }

    /// @notice 跟踪已经启动的验证者。
    /// @dev 跟踪此项是为了确保我们不会为同一个验证者公钥deposits两次，这是本合约和相关链下会计的基本假设。
    mapping(bytes pubkey => bool exists) public usedValidators;

    /// @inheritdoc IStakingManagerInitiationRead
    /// @dev 这是为了记录仍在传输中的 ETH，即已发送到deposits合约但尚未被信标链处理的 ETH。
    /// 一旦链下预言机检测到这些deposits，它们将在预言机合约中记录为 `totalDepositsProcessed` 以避免重复计数。
    uint256 public totalDepositedInValidators;

    uint256 public numInitiatedValidators;
    
    /// @notice 用于分配给deposit和填充待处理解除质押请求的 ETH 数量。
    uint256 public unallocatedETH;

    /// @notice 用于存入验证者的 ETH 数量。
    uint256 public allocatedETHForDeposits;

    /// @notice 用户可以质押的最小 ETH 数量。
    uint256 public minimumUnstakeBound;


    uint16 public exchangeAdjustmentRate;

    /// @dev 基点（通常表示为 bp，1bp = 0.01%）是金融中用于描述金融工具百分比变化的度量单位。
    /// 这是一个设置为 10000 的常量值，以基点表示 100%。
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice 管理员可以设置的最大汇率调整率（10%）。
    uint16 internal constant _MAX_EXCHANGE_ADJUSTMENT_RATE = _BASIS_POINTS_DENOMINATOR / 10; // 10%

    /// @notice 质押合约可以发送到存款合约以启动新验证者的最小 ETH 数量。
    /// @dev 这用作额外的保障，以防止发送会导致未激活验证者的存款（因为我们不做充值），
    /// 这些验证者需要再次退出才能拿回 ETH。
    uint256 public minimumDepositAmount;

    /// @notice 质押合约可以发送到存款合约以启动新验证者的最大 ETH 数量。
    /// @dev 这用作额外的保障，以防止发送过大的存款。虽然这不是关键问题，
    /// 因为任何超过 32 ETH（在撰写时）的盈余将在某个时候自动再次提取，
    /// 但仍然不理想，因为它会在往返期间锁定不赚取收益的 ETH，从而降低协议的效率。
    uint256 public maximumDepositAmount;

    /// @notice 接收信标链提款（即验证者奖励和退出）的地址。
    /// @dev 更改此变量不会立即生效，因为所有现有验证者仍将设置原始值。
    address public withdrawalWallet;

    /// @notice 质押白名单标志，启用时仅允许白名单中的地址进行质押。
    bool public isStakingAllowlist;

    /// @inheritdoc IStakingManagerInitiationRead
    /// @dev 这将用于为链下服务提供一个合理的起始时间点来开始他们的分析。
    uint256 public initializationBlockNumber;

    /// @notice 在质押过程中可以铸造的最大 dETH 数量。
    /// @dev 这用作额外的保障，在协议中创建最大质押金额。随着协议规模扩大，此值将增加以允许更多质押。
    uint256 public maximumDETHSupply;

    uint256 public unStakeMessageNonce;

    struct Init {
        address admin;
        address manager;
        address allocatorService;
        address initiatorService;
        address withdrawalWallet;
    }


    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约。
    /// @dev 必须在合约升级期间调用以设置代理的状态。
    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(STAKING_MANAGER_ROLE, init.manager);
        _grantRole(ALLOCATOR_SERVICE_ROLE, init.allocatorService);
        _grantRole(INITIATOR_SERVICE_ROLE, init.initiatorService);
        // 故意不将任何人设置为 TOP_UP_ROLE，因为它只会在需要充值功能的特殊情况下授予。
        withdrawalWallet = init.withdrawalWallet;

        minimumUnstakeBound = 0.01 ether;
        minimumDepositAmount = 32 ether;
        isStakingAllowlist = true;
        initializationBlockNumber = block.number;
        // 将最大 dETH 供应量设置为某个合理的金额，预计随着协议的扩大将发生变化。
        maximumDETHSupply = 1024 ether;
        unStakeMessageNonce = 0;
    }

    //function withdraw()external{
    //  msg.sender.call{value: address(this).balance}("");
    //}


    function stake(uint256 stakeAmount,IDETH.BatchMint[] calldata batchMints) external onlyDappLinkBridge payable {
        if (getL1Pauser().isStakingPaused()) {
            revert Paused();
        }

        if (msg.value < minimumDepositAmount || stakeAmount < minimumDepositAmount) {
            revert MinimumDepositAmountNotSatisfied();
        }

        uint256 dETHMintAmount = ethToDETH(stakeAmount);
        if (dETHMintAmount + getDETH().totalSupply() > maximumDETHSupply) {
            revert MaximumDETHSupplyExceeded();
        }

        unallocatedETH += stakeAmount;
        //批量铸造 dETH 给多个接收者
        getDETH().batchMint(batchMints);

        emit Staked(getLocator().dapplinkBridge(), stakeAmount, dETHMintAmount);
    }

    function unstakeRequest(uint128 dethAmount, uint128 minETHAmount, address l2Strategy, uint256 destChainId) external  {
        _unstakeRequest(dethAmount, minETHAmount, l2Strategy, destChainId);
    }

    /// @notice 通过将相应的 dETH 转移到质押合约并在解除质押请求管理器上创建请求来处理用户的解除质押请求。
    /// @param dethAmount 要解除质押的 dETH 数量。
    /// @param minETHAmount 用户期望获得的最小 ETH 数量。
    /// @param l2Strategy L2 上的策略合约地址 用于聚合请求
    /// @param destChainId 目标链 ID (L2 链 ID) 用于聚合请求
    function _unstakeRequest(uint128 dethAmount, uint128 minETHAmount, address l2Strategy, uint256 destChainId) internal {
        if (getL1Pauser().isUnstakeRequestsAndClaimsPaused()) {
            revert Paused();
        }

        if (dethAmount < minimumUnstakeBound) {
            revert MinimumUnstakeBoundNotSatisfied();
        }

        uint128 ethAmount = uint128(dETHToETH(dethAmount));
        //滑点保护: 检查 ETH 数量是否满足最小值
        if (ethAmount < minETHAmount) {
            revert UnstakeBelowMinimudETHAmount(ethAmount, minETHAmount);
        }
        //调用 UnstakeRequestsManager 创建请求
        getUnstakeRequestsManager().create({requester: msg.sender, l2Strategy: l2Strategy, dETHLocked: dethAmount, ethRequested: ethAmount, destChainId: destChainId});
        // 用于关联请求
        unStakeMessageNonce++;

        emit UnstakeRequested({staker: msg.sender, l2Strategy: l2Strategy, ethAmount: ethAmount, dETHLocked: dethAmount, destChainId: destChainId, unStakeMessageNonce: unStakeMessageNonce});

        //转移 dETH 到 UnstakeRequestsManager
        SafeERC20.safeTransferFrom(getDETH(), msg.sender, getLocator().unStakingRequestsManager(), dethAmount);
    }

    /// @notice Interface for users to claim their finalized and filled unstaking requests.
    /// @dev 另见 {UnstakeRequestsManager} 以获取有关完成和请求填充的更详细说明。
    function claimUnstakeRequest(IUnstakeRequestsManagerWrite.requestsInfo[] memory requests, uint256 sourceChainId, uint256 destChainId, uint256 gasLimit) external onlyRelayer {
        if (getL1Pauser().isUnstakeRequestsAndClaimsPaused()) {
            revert Paused();
        }
        getUnstakeRequestsManager().claim(requests, sourceChainId, destChainId, gasLimit);
    }


    function unstakeRequestInfo(uint256 destChainId, address l2strategy) external view  returns (bool, uint256) {
        return getUnstakeRequestsManager().requestInfo(destChainId, l2strategy);
    }

    /// @notice 从解除质押请求管理器提取任何盈余。
    /// @dev 请求管理器预计将通过使用 {receiveFromUnstakeRequestsManager} 推送资金来返还资金。
    function reclaimAllocatedETHSurplus() external onlyRole(STAKING_MANAGER_ROLE) {
        getUnstakeRequestsManager().withdrawAllocatedETHSurplus();
    }

    /// @notice 从 unallocatedETH 余额中分配 ETH 到解除质押请求管理器以填充待处理的请求，
    /// 并添加到用于启动新验证者的 allocatedETHForDeposits 余额。
    function allocateETH(uint256 allocateToUnstakeRequestsManager, uint256 allocateToDeposits)
        external
        onlyRole(ALLOCATOR_SERVICE_ROLE)
    {
        if (getL1Pauser().isAllocateETHPaused()) {
            revert Paused();
        }

        if (allocateToUnstakeRequestsManager + allocateToDeposits > unallocatedETH) {
            revert NotEnoughUnallocatedETH();
        }

        unallocatedETH -= allocateToUnstakeRequestsManager + allocateToDeposits;

        if (allocateToDeposits > 0) {
            allocatedETHForDeposits += allocateToDeposits;
            emit AllocatedETHToDeposits(allocateToDeposits);
        }

        if (allocateToUnstakeRequestsManager > 0) {
            emit AllocatedETHToUnstakeRequestsManager(allocateToUnstakeRequestsManager);
            getUnstakeRequestsManager().allocateETH{value: allocateToUnstakeRequestsManager}();
        }
    }

    /// @notice 通过将 ETH 发送到信标链deposits合约来启动新验证者。
    /// @dev 不能两次启动同一个验证者（公钥）。由于 BLS 签名无法在 EVM 上可行地验证，
    /// 调用者必须仔细确保发送的负载（公钥 + 签名）是正确的，否则发送的 ETH 将丢失。
    function initiateValidatorsWithDeposits(ValidatorParams[] calldata validators, bytes32 expectedDepositRoot)
        external
        onlyRole(INITIATOR_SERVICE_ROLE)
    {
        if (getL1Pauser().isInitiateValidatorsPaused()) {
            revert Paused();
        }
        if (validators.length == 0) {
            return;
        }
        // 检查deposits根是否与给定值匹配。这确保自提交交易以来deposits合约状态没有改变，
        // 这意味着恶意节点运营商无法抢跑deposits交易。
        bytes32 actualRoot = getDepositContract().get_deposit_root();
        if (expectedDepositRoot != actualRoot) {
            revert InvalidDepositRoot(actualRoot);
        }
        // 第一个循环是检查所有验证者是否符合我们的约束，并记录验证者以及我们存入的金额。
        uint256 amountDeposited = 0;
        for (uint256 i = 0; i < validators.length; ++i) {
            ValidatorParams calldata validator = validators[i];

            if (usedValidators[validator.pubkey]) {
                revert PreviouslyUsedValidator();
            }

            if (validator.depositAmount != minimumDepositAmount) {
                revert MinimumValidatorDepositNotSatisfied();
            }


            _requireProtocolWithdrawalAccount(validator.withdrawalCredentials);

            usedValidators[validator.pubkey] = true;
            amountDeposited += validator.depositAmount;

            emit ValidatorInitiated({
                id: keccak256(validator.pubkey),
                operatorID: validator.operatorID,
                pubkey: validator.pubkey,
                amountDeposited: validator.depositAmount
            });
        }

        if (amountDeposited > allocatedETHForDeposits) {
            revert NotEnoughDepositETH();
        }

        allocatedETHForDeposits -= amountDeposited;
        totalDepositedInValidators += amountDeposited;
        numInitiatedValidators += validators.length;

        // 第二个循环是将deposits发送到deposits合约。将外部调用与状态更改分开。
        for (uint256 i = 0; i < validators.length; ++i) {
            ValidatorParams calldata validator = validators[i];
            getDepositContract().deposit{value: validator.depositAmount}({
                pubkey: validator.pubkey,
                withdrawal_credentials: validator.withdrawalCredentials,
                signature: validator.signature,
                deposit_data_root: validator.depositDataRoot
            });
        }
    }

    /// @inheritdoc IStakingManagerReturnsWrite
    /// @dev 旨在在由 reclaimAllocatedETHSurplus() 启动的同一交易中调用。
    /// 这应该只在紧急情况下调用，例如，如果解除质押请求管理器已取消未完成的请求并且存在盈余余额。
    /// 将接收到的资金添加到未分配余额。
    function receiveFromUnstakeRequestsManager() external payable onlyUnstakeRequestsManager {
        unallocatedETH += msg.value;
    }

    /// @notice 为未分配的 ETH 余额充值以增加协议中的 ETH 数量。
    /// @dev 绕过收益聚合器费用收集，直接将 ETH 注入协议。
    function topUp() external payable onlyRole(TOP_UP_ROLE) {
        unallocatedETH += msg.value;
    }

    /// @notice 使用当前汇率将 ETH 转换为 dETH。
    /// 汇率由 dETH 的总供应量和协议控制的总 ETH 给出。
    function ethToDETH(uint256 ethAmount) public returns (uint256) {
        if (getDETH().totalSupply() == 0) {
            return ethAmount; // 初始汇率 1:1
        }
        // dETH 数量 = ethAmount * totalSupply / totalControlled
        return Math.mulDiv(
            ethAmount,
            getDETH().totalSupply() * uint256(_BASIS_POINTS_DENOMINATOR - exchangeAdjustmentRate),
            totalControlled() * uint256(_BASIS_POINTS_DENOMINATOR)
        );
    }

    function dETHToETH(uint256 dETHAmount) public returns (uint256) {
        if (getDETH().totalSupply() == 0) {
            return dETHAmount;
        }
        return Math.mulDiv(dETHAmount, totalControlled(), getDETH().totalSupply());
    }

    /// @notice 协议控制的 ETH 总量。
    /// @dev 对各种合约的余额和来自预言机的信标链信息求和。
    function totalControlled() public returns (uint256) {
        OracleRecord memory record = IOracleReadRecord(getLocator().oracleManager()).latestRecord();
        uint256 total = 0;
        total += unallocatedETH;
        total += allocatedETHForDeposits;
        /// 存入信标链的总 ETH 必须减去链下预言机处理的deposits，
        /// 因为从那时起它将在 currentTotalValidatorBalance 中记录。
        total += totalDepositedInValidators - record.cumulativeProcessedDepositAmount;
        total += record.currentTotalValidatorBalance;
        total += getUnstakeRequestsManager().balance();
        return total;
    }

    /// @notice 检查给定的提款凭证是否是有效的 0x01 前缀提款地址。
    /// @dev 另见
    /// https://github.com/ethereum/consensus-specs/blob/master/specs/phase0/validator.md#eth1_address_withdrawal_prefix
    function _requireProtocolWithdrawalAccount(bytes calldata withdrawalCredentials) internal view {
        if (withdrawalCredentials.length != 32) {
            revert InvalidWithdrawalCredentialsWrongLength(withdrawalCredentials.length);
        }

        bytes12 prefixAndPadding = bytes12(withdrawalCredentials[:12]);
        if (prefixAndPadding != 0x010000000000000000000000) {
            revert InvalidWithdrawalCredentialsNotETH1(prefixAndPadding);
        }

        address addr = address(bytes20(withdrawalCredentials[12:32]));
        if (addr != withdrawalWallet) {
            revert InvalidWithdrawalCredentialsWrongAddress(addr);
        }
    }

    /// @inheritdoc IStakingManagerReturnsWrite
    /// @dev 将接收到的资金添加到未分配余额。
    function receiveReturns() external payable onlyReturnsAggregator {
        emit ReturnsReceived(msg.value);
        unallocatedETH += msg.value;
    }


    /// @notice 确保调用者是收益聚合器。
    modifier onlyReturnsAggregator() {
        if (msg.sender != getLocator().returnsAggregator()) {
            revert NotReturnsAggregator();
        }
        _;
    }

    /// @notice 确保调用者是解除质押请求管理器。
    modifier onlyUnstakeRequestsManager() {
        if (msg.sender != getLocator().unStakingRequestsManager()) {
            revert NotUnstakeRequestsManager();
        }
        _;
    }

    modifier onlyDappLinkBridge() {
        if (msg.sender != getLocator().dapplinkBridge()) {
            revert NotDappLinkBridge();
        }
        _;
    }

    /// @notice 设置用户可以解除质押的最小 dETH 数量。
    function setMinimumUnstakeBound(uint256 minimumUnstakeBound_) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumUnstakeBound = minimumUnstakeBound_;
        emit ProtocolConfigChanged(
            this.setMinimumUnstakeBound.selector, "setMinimumUnstakeBound(uint256)", abi.encode(minimumUnstakeBound_)
        );
    }

    /// @notice 设置质押调整率。
    function setExchangeAdjustmentRate(uint16 exchangeAdjustmentRate_) external onlyRole(STAKING_MANAGER_ROLE) {
        if (exchangeAdjustmentRate_ > _MAX_EXCHANGE_ADJUSTMENT_RATE) {
            revert InvalidConfiguration();
        }

        assert(exchangeAdjustmentRate_ <= _BASIS_POINTS_DENOMINATOR);

        exchangeAdjustmentRate = exchangeAdjustmentRate_;
        emit ProtocolConfigChanged(
            this.setExchangeAdjustmentRate.selector,
            "setExchangeAdjustmentRate(uint16)",
            abi.encode(exchangeAdjustmentRate_)
        );
    }

    /// @notice 设置质押合约可以发送到deposits合约以启动新验证者的最小 ETH 数量。
    function setMinimumDepositAmount(uint256 minimumDepositAmount_) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumDepositAmount = minimumDepositAmount_;
        emit ProtocolConfigChanged(
            this.setMinimumDepositAmount.selector, "setMinimumDepositAmount(uint256)", abi.encode(minimumDepositAmount_)
        );
    }

    /// @notice 设置 maximumDETHSupply 变量。
    function setMaximumDETHSupply(uint256 maximumDETHSupply_) external onlyRole(STAKING_MANAGER_ROLE) {
        maximumDETHSupply = maximumDETHSupply_;
        emit ProtocolConfigChanged(
            this.setMaximumDETHSupply.selector, "setMaximumDETHSupply(uint256)", abi.encode(maximumDETHSupply_)
        );
    }

    /// @notice 设置接收信标链提款（即验证者奖励和退出）的地址。
    /// @dev 更改此变量不会立即生效，因为所有现有验证者仍将设置原始值。
    function setWithdrawalWallet(address withdrawalWallet_)
        external
        onlyRole(STAKING_MANAGER_ROLE)
        notZeroAddress(withdrawalWallet_)
    {
        withdrawalWallet = withdrawalWallet_;
        emit ProtocolConfigChanged(
            this.setWithdrawalWallet.selector, "setWithdrawalWallet(address)", abi.encode(withdrawalWallet_)
        );
    }

    /// @notice 设置质押白名单标志。
    function setStakingAllowlist(bool isStakingAllowlist_) external onlyRole(STAKING_MANAGER_ROLE) {
        isStakingAllowlist = isStakingAllowlist_;
        emit ProtocolConfigChanged(
            this.setStakingAllowlist.selector, "setStakingAllowlist(bool)", abi.encode(isStakingAllowlist_)
        );
    }

    receive() external payable {
        unallocatedETH += msg.value;
        // revert DoesNotReceiveETH();
    }

    // fallback() external payable {
    //     revert DoesNotReceiveETH();
    // }
}