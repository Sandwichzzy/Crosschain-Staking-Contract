// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../libraries/EIP1271SignatureUtils.sol";
import "./DelegationManagerStorage.sol";
import {L2Base} from "./L2Base.sol";

contract DelegationManager is L2Base, DelegationManagerStorage {
    uint8 internal constant PAUSED_NEW_DELEGATION = 0;

    uint8 internal constant PAUSED_ENTER_WITHDRAWAL_QUEUE = 1;

    uint8 internal constant PAUSED_EXIT_WITHDRAWAL_QUEUE = 2;

    uint256 internal immutable ORIGINAL_CHAIN_ID;

    uint256 public constant MAX_STAKER_OPT_OUT_WINDOW_BLOCKS = (180 days) / 12;

    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/
    constructor() {
        _disableInitializers();
        ORIGINAL_CHAIN_ID = block.chainid;
    }

    function initialize(
        address initialOwner,
        uint256 _minWithdrawalDelayBlocks,
        address[] calldata _strategies,
        uint256[] calldata _withdrawalDelayBlocks
    ) external initializer {
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        __L2Base_init(initialOwner);
        _setMinWithdrawalDelayBlocks(_minWithdrawalDelayBlocks);
        _setStrategyWithdrawalDelayBlocks(_strategies, _withdrawalDelayBlocks);
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS
    *******************************************************************************/

    //将operator的链下信息提交到链上，例如：节点p2p通信链接
    function registerAsOperator(OperatorDetails calldata registeringOperatorDetails, string calldata nodeUrl) external {
        require(
            _operatorDetails[msg.sender].earningsReceiver == address(0),
            "DelegationManager.registerAsOperator: operator has already registered"
        );
        _setOperatorDetails(msg.sender, registeringOperatorDetails);
        SignatureWithExpiry memory emptySignatureAndExpiry;
        //将 operator 自己质押的份额 shares 委托给自己（operator 即是 staker 也是 operator）
        _delegate(msg.sender, msg.sender, emptySignatureAndExpiry, bytes32(0));
        emit OperatorRegistered(msg.sender, registeringOperatorDetails);
        emit OperatorNodeUrlUpdated(msg.sender, nodeUrl);
    }

    function modifyOperatorDetails(OperatorDetails calldata newOperatorDetails) external {
        require(isOperator(msg.sender), "DelegationManager.modifyOperatorDetails: caller must be an operator");
        _setOperatorDetails(msg.sender, newOperatorDetails);
    }

    function updateOperatorNodeUrl(string calldata nodeUrl) external {
        require(isOperator(msg.sender), "DelegationManager.updateOperatorNodeUrl: caller must be an operator");
        emit OperatorNodeUrlUpdated(msg.sender, nodeUrl);
    }

    function delegateTo(address operator, SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt)
        external
    {
        _delegate(msg.sender, operator, approverSignatureAndExpiry, approverSalt);
    }

    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external {
        require(
            stakerSignatureAndExpiry.expiry >= block.timestamp,
            "DelegationManager.delegateToBySignature: staker signature expired"
        );

        uint256 currentStakerNonce = stakerNonce[staker];
        bytes32 stakerDigestHash =
            calculateStakerDelegationDigestHash(staker, currentStakerNonce, operator, stakerSignatureAndExpiry.expiry);
        unchecked {
            stakerNonce[staker] = currentStakerNonce + 1;
        }

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, stakerDigestHash, stakerSignatureAndExpiry.signature);

        _delegate(staker, operator, approverSignatureAndExpiry, approverSalt);
    }


    //解质押会触发staker全部取款
    function undelegate(address staker) external returns (bytes32[] memory withdrawalRoots) {
        require(getL2Pauser().isUnDelegate(), "DelegationManager:undelegate paused");
        //staker 必须已经被委托才能undelegate
        require(isDelegated(staker), "DelegationManager.undelegate: staker must be delegated to undelegate");
        require(!isOperator(staker), "DelegationManager.undelegate: operators cannot be undelegated");
        require(staker != address(0), "DelegationManager.undelegate: cannot undelegate zero address");
        address operator = delegatedTo[staker];
        //只能是staker本人，operator，或者operator的delegationApprover来调用undelegate函数
        require(
            msg.sender == staker || msg.sender == operator
                || msg.sender == _operatorDetails[operator].delegationApprover,
            "DelegationManager.undelegate: caller cannot undelegate staker"
        );
        //获取staker在各个策略中质押的shares，返回数组
        (address[] memory strategies, uint256[] memory shares) = getDelegatableShares(staker);

        if (msg.sender != staker) {
            emit StakerForceUndelegated(staker, operator);
        }

        emit StakerUndelegated(staker, operator);
        delegatedTo[staker] = address(0);        //将staker和operator之间的委托关系移除

        // 为每个策略创建单独的提款队列
        if (strategies.length == 0) {
            withdrawalRoots = new bytes32[](0);
        } else {
            withdrawalRoots = new bytes32[](strategies.length);
            for (uint256 i = 0; i < strategies.length; i++) {
                address[] memory singleStrategy = new address[](1);
                uint256[] memory singleShare = new uint256[](1);
                singleStrategy[0] = strategies[i];
                singleShare[0] = shares[i];
                //将staker委托给operator的shares移除，并将staker在策略里面shares清0, 生成排队取款的交易
                withdrawalRoots[i] = _removeSharesAndQueueWithdrawal({
                    staker: staker,
                    operator: operator,
                    withdrawer: staker,
                    strategies: singleStrategy,
                    shares: singleShare
                });
            }
        }

        return withdrawalRoots;
    }

    //部分取款，和undelegate区别是没有解除委托关系
    function queueWithdrawals(QueuedWithdrawalParams[] calldata queuedWithdrawalParams)
        external
        returns (bytes32[] memory)
    {
        require(getL2Pauser().isStakerWithdraw(), "DelegationManager:queueWithdrawals paused");
        bytes32[] memory withdrawalRoots = new bytes32[](queuedWithdrawalParams.length);
        address operator = delegatedTo[msg.sender];

        for (uint256 i = 0; i < queuedWithdrawalParams.length; i++) {
            require(
                queuedWithdrawalParams[i].strategies.length == queuedWithdrawalParams[i].shares.length,
                "DelegationManager.queueWithdrawal: input length mismatch"
            );
            // require(queuedWithdrawalParams[i].withdrawer == msg.sender, "DelegationManager.queueWithdrawal: withdrawer must be staker");
            withdrawalRoots[i] = _removeSharesAndQueueWithdrawal({
                staker: queuedWithdrawalParams[i].withdrawer,
                operator: operator,
                withdrawer: queuedWithdrawalParams[i].withdrawer,
                strategies: queuedWithdrawalParams[i].strategies,
                shares: queuedWithdrawalParams[i].shares
            });
        }
        return withdrawalRoots;
    }

    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        IERC20 weth,
        uint256 middlewareTimesIndex,
        bool receiveAsWeth
    ) external nonReentrant {
        require(getL2Pauser().isStakerWithdraw(), "DelegationManager:completeQueuedWithdrawal paused");
        _completeQueuedWithdrawal(withdrawal, weth, middlewareTimesIndex, receiveAsWeth);
    }

    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        IERC20 weth,
        uint256[] calldata middlewareTimesIndexes,
        bool[] calldata receiveAsWeth
    ) external nonReentrant {
        require(getL2Pauser().isStakerWithdraw(), "DelegationManager:completeQueuedWithdrawals paused");
        for (uint256 i = 0; i < withdrawals.length; ++i) {
            _completeQueuedWithdrawal(withdrawals[i], weth, middlewareTimesIndexes[i], receiveAsWeth[i]);
        }
    }


    function increaseDelegatedShares(address staker, address strategy, uint256 shares) external onlyStrategyManager {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];
            _increaseOperatorShares({operator: operator, staker: staker, strategy: strategy, shares: shares});
        }
    }

    function decreaseDelegatedShares(address staker, address strategy, uint256 shares) external onlyStrategyManager {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];
            _decreaseOperatorShares({operator: operator, staker: staker, strategy: strategy, shares: shares});
        }
    }

    function setMinWithdrawalDelayBlocks(uint256 newMinWithdrawalDelayBlocks) external onlyOwner {
        _setMinWithdrawalDelayBlocks(newMinWithdrawalDelayBlocks);
    }

    function setStrategyWithdrawalDelayBlocks(address[] calldata strategies, uint256[] calldata withdrawalDelayBlocks)
        external
        onlyOwner
    {
        _setStrategyWithdrawalDelayBlocks(strategies, withdrawalDelayBlocks);
    }

    /*******************************************************************************
                            INTERNAL FUNCTIONS
    *******************************************************************************/
    function _setOperatorDetails(address operator, OperatorDetails calldata newOperatorDetails) internal {
        require(
            newOperatorDetails.earningsReceiver != address(0),
            "DelegationManager._setOperatorDetails: cannot set `earningsReceiver` to zero address"
        );
        require(
            newOperatorDetails.stakerOptOutWindowBlocks <= MAX_STAKER_OPT_OUT_WINDOW_BLOCKS,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be > MAX_STAKER_OPT_OUT_WINDOW_BLOCKS"
        );
        require(
            newOperatorDetails.stakerOptOutWindowBlocks >= _operatorDetails[operator].stakerOptOutWindowBlocks,
            "DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be decreased"
        );
        _operatorDetails[operator] = newOperatorDetails;
        emit OperatorDetailsModified(msg.sender, newOperatorDetails);
    }

    function _delegate(
        address staker,
        address operator,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) internal {
        require(getL2Pauser().isDelegate(), "DelegationManager:isDelegate paused");
        //判断staker是否已经委托给了某个operator，operator是否已经注册
        require(!isDelegated(staker), "DelegationManager._delegate: staker is already actively delegated");
        require(isOperator(operator), "DelegationManager._delegate: operator is not registered in DappLink");

        address _delegationApprover = _operatorDetails[operator].delegationApprover;
        //授权者验证
        if (_delegationApprover != address(0) && msg.sender != _delegationApprover && msg.sender != operator) {
            require(
                approverSignatureAndExpiry.expiry >= block.timestamp,
                "DelegationManager._delegate: approver signature expired"
            );

            require(
                !delegationApproverSaltIsSpent[_delegationApprover][approverSalt],
                "DelegationManager._delegate: approverSalt already spent"
            );
            delegationApproverSaltIsSpent[_delegationApprover][approverSalt] = true;

            bytes32 approverDigestHash = calculateDelegationApprovalDigestHash(
                staker, operator, _delegationApprover, approverSalt, approverSignatureAndExpiry.expiry
            );

            EIP1271SignatureUtils.checkSignature_EIP1271(
                staker, approverDigestHash, approverSignatureAndExpiry.signature
            );
        }
        //将operator和staker的委托关系记录在链上
        delegatedTo[staker] = operator;
        emit StakerDelegated(staker, operator);
        //获取staker在各个策略中质押的shares
        (address[] memory strategies, uint256[] memory shares) = getDelegatableShares(staker);
        //将staker在各个策略中的质押份额shares 委托给 operator
        for (uint256 i = 0; i < strategies.length;) {
            //使用命名参数调用函数，提升可读性， 参数顺序可以任意调整
            _increaseOperatorShares({operator: operator, staker: staker, strategy: strategies[i], shares: shares[i]});
            //禁用溢出检查 节省gas
            unchecked {
                ++i;
            }
        }
    }

    function _completeQueuedWithdrawal(Withdrawal calldata withdrawal, IERC20 weth, uint256, bool receiveAsWeth)
        internal
    {
        bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);

        // require(
        //     pendingWithdrawals[withdrawalRoot],
        //     "DelegationManager._completeQueuedWithdrawal: action is not in queue"
        // );

        // require(
        //     withdrawal.startBlock + minWithdrawalDelayBlocks <= block.number,
        //     "DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed"
        // );

        require(
            msg.sender == withdrawal.withdrawer,
            "DelegationManager._completeQueuedWithdrawal: only withdrawer can complete action"
        );

//        删除待处理标记
        delete pendingWithdrawals[withdrawalRoot];
        address currentOperator = delegatedTo[msg.sender];
        if (receiveAsWeth) {
            // 选项 A: 提取为 WETH
            for (uint256 i = 0; i < withdrawal.strategies.length;) {
                // 检查延迟期
                require(
                    withdrawal.startBlock + strategyWithdrawalDelayBlocks[withdrawal.strategies[i]] <= block.number,
                    "DelegationManager._completeQueuedWithdrawal: withdrawalDelayBlocks period has not yet passed for this strategy"
                );
                // 调用 StrategyManager 提取为 WETH
                _withdrawSharesAsWeth({
                    withdrawer: msg.sender, strategy: withdrawal.strategies[i], shares: withdrawal.shares[i], weth: weth
                });
                unchecked {
                    ++i;
                }
                emit WithdrawalCompleted(currentOperator, msg.sender, withdrawal.strategies[i], withdrawal.shares[i]);
            }
        } else {
            // 选项 B: 重新质押 (恢复份额)
            for (uint256 i = 0; i < withdrawal.strategies.length;) {
                // require(
                //     withdrawal.startBlock + strategyWithdrawalDelayBlocks[withdrawal.strategies[i]] <= block.number,
                //     "DelegationManager._completeQueuedWithdrawal: withdrawalDelayBlocks period has not yet passed for this strategy"
                // );
                // 恢复 StrategyManager 中的份额
                getStrategyManager().addShares(msg.sender, weth, withdrawal.strategies[i], withdrawal.shares[i]);
                // 如果当前已委托,恢复运营商份额
                if (currentOperator != address(0)) {
                    _increaseOperatorShares({
                        operator: currentOperator,
                        staker: msg.sender,
                        strategy: withdrawal.strategies[i],
                        shares: withdrawal.shares[i]
                    });
                }
                unchecked {
                    ++i;
                }
                emit WithdrawalCompleted(currentOperator, msg.sender, withdrawal.strategies[i], withdrawal.shares[i]);
            }
        }
        // emit WithdrawalCompleted(withdrawalRoot);
    }

    function _increaseOperatorShares(address operator, address staker, address strategy, uint256 shares) internal {
        operatorShares[operator][strategy] += shares;
        stakerStrategyOperatorShares[operator][strategy][staker] += shares;
        emit OperatorSharesIncreased(operator, staker, strategy, shares);
    }

    function _decreaseOperatorShares(address operator, address staker, address strategy, uint256 shares) internal {
        operatorShares[operator][strategy] -= shares;
        stakerStrategyOperatorShares[operator][strategy][staker] -= shares;
        emit OperatorSharesDecreased(operator, staker, strategy, shares);
    }

    function _removeSharesAndQueueWithdrawal(
        address staker,
        address operator,
        address withdrawer,
        address[] memory strategies,
        uint256[] memory shares
    ) internal returns (bytes32) {
        require(
            staker != address(0), "DelegationManager._removeSharesAndQueueWithdrawal: staker cannot be zero address"
        );
        require(strategies.length != 0, "DelegationManager._removeSharesAndQueueWithdrawal: strategies cannot be empty");
        // 1. 遍历策略,移除份额
        for (uint256 i = 0; i < strategies.length;) {
            //检查 L1 返还的份额 防止用户提取尚未从 L1 迁移的份额
            uint256 l1BackShares = getStrategyManager().getStakerStrategyL1BackShares(staker, strategies[i]);
            // 只有 l1BackShares >= shares[i] 时才处理
            if (l1BackShares >= shares[i]) {
                if (operator != address(0)) {
                    _decreaseOperatorShares({
                        operator: operator, staker: staker, strategy: strategies[i], shares: shares[i]
                    });
                }
                require(
                    staker == withdrawer || !getStrategyManager().thirdPartyTransfersForbidden(strategies[i]),
                    "DelegationManager._removeSharesAndQueueWithdrawal: withdrawer must be same address as staker if thirdPartyTransfersForbidden are set"
                );
                // 调用 StrategyManager 移除staker份额
                getStrategyManager().removeShares(staker, strategies[i], shares[i]);

                unchecked {
                    ++i;
                }
            }
        }
        // 2. 生成 nonce 并递增
        uint256 nonce = cumulativeWithdrawalsQueued[staker];
        cumulativeWithdrawalsQueued[staker]++;
        // 3. 创建 Withdrawal 对象
        Withdrawal memory withdrawal = Withdrawal({
            staker: staker,
            delegatedTo: operator,
            withdrawer: withdrawer,
            nonce: nonce,
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: shares
        });

        bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);

        pendingWithdrawals[withdrawalRoot] = true;

        emit WithdrawalQueued(withdrawalRoot, withdrawal);
        return withdrawalRoot;
    }

    function _withdrawSharesAsWeth(address withdrawer, address strategy, uint256 shares, IERC20 weth) internal {
        getStrategyManager().withdrawSharesAsWeth(withdrawer, strategy, shares, weth);
    }

    function _setMinWithdrawalDelayBlocks(uint256 _minWithdrawalDelayBlocks) internal {
        require(
            _minWithdrawalDelayBlocks <= MAX_WITHDRAWAL_DELAY_BLOCKS,
            "DelegationManager._setMinWithdrawalDelayBlocks: _minWithdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS"
        );
        emit MinWithdrawalDelayBlocksSet(minWithdrawalDelayBlocks, _minWithdrawalDelayBlocks);
        minWithdrawalDelayBlocks = _minWithdrawalDelayBlocks;
    }

    function _setStrategyWithdrawalDelayBlocks(
        address[] calldata _strategies,
        uint256[] calldata _withdrawalDelayBlocks
    ) internal {
        require(
            _strategies.length == _withdrawalDelayBlocks.length,
            "DelegationManager._setStrategyWithdrawalDelayBlocks: input length mismatch"
        );
        uint256 numStrats = _strategies.length;
        for (uint256 i = 0; i < numStrats; ++i) {
            address strategy = _strategies[i];
            uint256 prevStrategyWithdrawalDelayBlocks = strategyWithdrawalDelayBlocks[strategy];
            uint256 newStrategyWithdrawalDelayBlocks = _withdrawalDelayBlocks[i];
            require(
                newStrategyWithdrawalDelayBlocks <= MAX_WITHDRAWAL_DELAY_BLOCKS,
                "DelegationManager._setStrategyWithdrawalDelayBlocks: _withdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS"
            );

            strategyWithdrawalDelayBlocks[strategy] = newStrategyWithdrawalDelayBlocks;
            emit StrategyWithdrawalDelayBlocksSet(
                strategy, prevStrategyWithdrawalDelayBlocks, newStrategyWithdrawalDelayBlocks
            );
        }
    }

    /*******************************************************************************
                            VIEW FUNCTIONS
    *******************************************************************************/
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        } else {
            return _calculateDomainSeparator();
        }
    }

    function isDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] != address(0));
    }

    function isOperator(address operator) public view returns (bool) {
        return (_operatorDetails[operator].earningsReceiver != address(0));
    }

    function operatorDetails(address operator) external view returns (OperatorDetails memory) {
        return _operatorDetails[operator];
    }

    function earningsReceiver(address operator) external view returns (address) {
        return _operatorDetails[operator].earningsReceiver;
    }

    function delegationApprover(address operator) external view returns (address) {
        return _operatorDetails[operator].delegationApprover;
    }

    function stakerOptOutWindowBlocks(address operator) external view returns (uint256) {
        return _operatorDetails[operator].stakerOptOutWindowBlocks;
    }

    function getOperatorShares(address operator, address[] memory strategies) public view returns (uint256[] memory) {
        uint256[] memory shares = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; ++i) {
            shares[i] = operatorShares[operator][strategies[i]];
        }
        return shares;
    }

    function getDelegatableShares(address staker) public view returns (address[] memory, uint256[] memory) {
        (address[] memory strategyManagerStrats, uint256[] memory strategyManagerShares) =
            getStrategyManager().getDeposits(staker);
        return (strategyManagerStrats, strategyManagerShares);
    }

    function getWithdrawalDelay(address[] calldata strategies) public view returns (uint256) {
        uint256 withdrawalDelay = minWithdrawalDelayBlocks;
        for (uint256 i = 0; i < strategies.length; ++i) {
            uint256 currWithdrawalDelay = strategyWithdrawalDelayBlocks[strategies[i]];
            if (currWithdrawalDelay > withdrawalDelay) {
                withdrawalDelay = currWithdrawalDelay;
            }
        }
        return withdrawalDelay;
    }

    function calculateWithdrawalRoot(Withdrawal memory withdrawal) public pure returns (bytes32) {
        return keccak256(abi.encode(withdrawal));
    }

    function calculateCurrentStakerDelegationDigestHash(address staker, address operator, uint256 expiry)
        external
        view
        returns (bytes32)
    {
        uint256 currentStakerNonce = stakerNonce[staker];
        return calculateStakerDelegationDigestHash(staker, currentStakerNonce, operator, expiry);
    }

    function calculateStakerDelegationDigestHash(
        address staker,
        uint256 _stakerNonce,
        address operator,
        uint256 expiry
    ) public view returns (bytes32) {
        bytes32 stakerStructHash =
            keccak256(abi.encode(STAKER_DELEGATION_TYPEHASH, staker, operator, _stakerNonce, expiry));

        bytes32 stakerDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), stakerStructHash));
        return stakerDigestHash;
    }

    function calculateDelegationApprovalDigestHash(
        address staker,
        address operator,
        address _delegationApprover,
        bytes32 approverSalt,
        uint256 expiry
    ) public view returns (bytes32) {
        bytes32 approverStructHash = keccak256(
            abi.encode(DELEGATION_APPROVAL_TYPEHASH, staker, operator, _delegationApprover, approverSalt, expiry)
        );

        bytes32 approverDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), approverStructHash));
        return approverDigestHash;
    }

    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("DappLink")), block.chainid, address(this)));
    }
}
