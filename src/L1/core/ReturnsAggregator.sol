// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import  "@openzeppelin/contracts/utils/math/Math.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import {L1Base} from "./L1Base.sol";
import { IOracleReadRecord, OracleRecord } from "../interfaces/IOracleManager.sol";
import { IStakingManagerReturnsWrite } from "../interfaces/IStakingManager.sol";
import { IReturnsAggregator } from "../interfaces/IReturnsAggregator.sol";

import { ReturnsReceiver } from "./ReturnsReceiver.sol";
import "../../libraries/SafeCall.sol";

/// @title ReturnsAggregator 收益聚合器
/// @notice 聚合器合约，聚合协议控制的钱包中的收益，在适用情况下收取费用，并将净收益转发到质押合约。
contract ReturnsAggregator is L1Base, IReturnsAggregator {

    /// @notice 管理员角色，可以设置费用接收钱包和费用基点。
    bytes32 public constant AGGREGATOR_MANAGER_ROLE = keccak256("AGGREGATOR_MANAGER_ROLE");

    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice 接收协议费用的地址。
    address payable public feesReceiver;

    /// @notice 协议费用基点（1/10000）。
    uint16 public feesBasisPoints;

    uint256 public gasLimit = 21000;

    struct Init {
        address admin;
        address manager;
        address payable feesReceiver;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(AGGREGATOR_MANAGER_ROLE, init.manager);
        feesReceiver = init.feesReceiver;
        feesBasisPoints = 1_000;
    }

    /// @inheritdoc IReturnsAggregator
    /// @dev 计算要转发到质押合约的资金数量,收取费用并转发。
    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards, address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId)
        external
        assertBalanceUnchanged
    {
        if (msg.sender != getLocator().oracleManager()) {
            revert NotOracle();
        }

        // 计算将聚合的收益总额。
        uint256 clTotal = rewardAmount + principalAmount;
        uint256 totalRewards = rewardAmount;

        uint256 elRewards = 0;
        if (shouldIncludeELRewards) {
            elRewards = getLocator().executionLayerReceiver().balance;
            totalRewards += elRewards;
        }
        // 计算协议费用。
        uint256 fees = Math.mulDiv(feesBasisPoints, totalRewards, _BASIS_POINTS_DENOMINATOR);

        // 在此合约中聚合收益
        address payable self = payable(address(this));
        if (elRewards > 0) {
            bool success = SafeCall.callWithMinGas(
                bridge,
                gasLimit,
                elRewards,
                abi.encodeWithSignature("BridgeInitiateETH(uint256,uint256,address)", sourceChainId, destChainId, l2Strategy)
            );
            require(success, "BridgeInitiateETH failed");
        }
        if (clTotal > 0) {
            ReturnsReceiver(payable (getLocator().consensusLayerReceiver())).transfer(self, clTotal);
        }

        // 将净收益（如果存在）转发到质押合约。
        uint256 netReturns = clTotal + elRewards - fees;
        if (netReturns > 0) {
            IStakingManagerReturnsWrite(getLocator().stakingManager()).receiveReturns{value: netReturns}();
        }

        // 将协议费用（如果存在）发送到费用接收钱包。
        if (fees > 0) {
            emit FeesCollected(fees);
            Address.sendValue(feesReceiver, fees);
        }
    }

    /// @notice 设置协议的费用接收钱包。
    /// @param newReceiver 新的费用接收钱包。
    function setFeesReceiver(address payable newReceiver)
        external
        onlyRole(AGGREGATOR_MANAGER_ROLE)
        notZeroAddress(newReceiver)
    {
        feesReceiver = newReceiver;
        emit ProtocolConfigChanged(this.setFeesReceiver.selector, "setFeesReceiver(address)", abi.encode(newReceiver));
    }


    /// @notice 设置费用基点。
    /// @param newBasisPoints 新的费用基点。
    function setFeeBasisPoints(uint16 newBasisPoints) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (newBasisPoints > _BASIS_POINTS_DENOMINATOR) {
            revert InvalidConfiguration();
        }

        feesBasisPoints = newBasisPoints;
        emit ProtocolConfigChanged(
            this.setFeeBasisPoints.selector, "setFeeBasisPoints(uint16)", abi.encode(newBasisPoints)
        );
    }

    receive() external payable {}

    /// @notice 确保函数返回后合约余额保持不变。
    modifier assertBalanceUnchanged() {
        uint256 before = address(this).balance;
        _;
        assert(address(this).balance == before);
    }
}