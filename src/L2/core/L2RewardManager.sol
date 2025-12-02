// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2RewardManagerStorage} from "./L2RewardManagerStorage.sol";
import {L2Base} from "./L2Base.sol";

/// @title L2RewardManager - L2 层收益管理合约
/// @notice 管理 L2 原生代币(DappLink Token)的奖励分配,按运营商和质押者分配收益
/// @dev 将收益按比例分配给运营商和质押者,默认质押者获得 92%,运营商获得 8%
contract L2RewardManager is L2Base, L2RewardManagerStorage {
    using SafeERC20 for IERC20;

    /// @notice 质押者收益占比(默认 92%)
    uint256 public stakerPercent = 92;

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化 L2 奖励管理合约
    /// @param initialOwner 初始所有者地址
    function initialize(address initialOwner) external initializer {
        __L2Base_init(initialOwner);
    }

    /// @notice 计算并分配手续费给运营商和质押者
    /// @dev 根据运营商份额占策略总份额的比例,计算运营商应得的总手续费,然后按比例分配给质押者和运营商
    /// @param strategy 策略地址
    /// @param operator 运营商地址
    /// @param baseFee 基础手续费金额
    function calculateFee(address strategy, address operator, uint256 baseFee) external {
        // 获取策略的总份额
        uint256 totalShares = getStrategy(strategy).totalShares();
        // 获取运营商在该策略中的份额
        uint256 operatorShares = getDelegationManager().operatorShares(operator, strategy);
        // 计算运营商应得的总手续费: baseFee * (运营商份额 / 策略总份额)
        uint256 operatorTotalFee = (baseFee * operatorShares) / totalShares;

        // 计算质押者部分的手续费(92%)
        uint256 stakerFee = (operatorTotalFee * stakerPercent) / 100;
        stakerRewards[strategy] = stakerFee;

        // 计算运营商部分的手续费(8%)
        uint256 operatorFee = (operatorTotalFee * (100 - stakerPercent)) / 100;
        operatorRewards[operator] = operatorFee;

        emit OperatorStakerReward(strategy, operator, stakerFee, operatorFee);
    }

    /// @notice 存入 DappLink 代币作为奖励
    /// @dev 任何人都可以调用此函数向奖励池充值 DappLink 代币
    /// @param amount 存入的代币数量
    /// @return 是否成功
    function depositDappLinkToken(uint256 amount) external returns (bool) {
        getDapplinkToken().safeTransferFrom(msg.sender, address(this), amount);
        emit DepositDappLinkToken(msg.sender, amount);
        return true;
    }

    /// @notice 运营商申领奖励
    /// @dev 运营商提取其累积的 DappLink 代币奖励
    /// @return 是否成功
    function operatorClaimReward() external returns (bool) {
        uint256 claimAmount = operatorRewards[msg.sender];
        require(claimAmount > 0, "No rewards to claim");
        // 清零防止重复申领
        operatorRewards[msg.sender] = 0;

        getDapplinkToken().safeTransferFrom(address(this), msg.sender, claimAmount);
        emit OperatorClaimReward(msg.sender, claimAmount);
        return true;
    }

    /// @notice 质押者申领奖励
    /// @dev 质押者提取其在指定策略中的 DappLink 代币奖励
    /// @param strategy 策略地址
    /// @return 是否成功
    function stakerClaimReward(address strategy) external returns (bool) {
        uint256 stakerAmount = stakerRewardsAmount(strategy);
        require(stakerAmount > 0, "No rewards to claim");
        claimedStakerRewards[strategy][msg.sender] += stakerAmount;
        getDapplinkToken().safeTransferFrom(address(this), msg.sender, stakerAmount);
        emit StakerClaimReward(msg.sender, stakerAmount);
        return true;
    }

    /// @notice 计算质押者在指定策略中可获得的奖励金额
    /// @dev 根据质押者份额占策略总份额的比例计算奖励
    /// @param strategy 策略地址
    /// @return 质押者可获得的奖励金额
    function stakerRewardsAmount(address strategy) public view returns (uint256) {
        // 获取质押者在该策略中的份额
        uint256 stakerShare = getStrategyManager().getStakerStrategyShares(msg.sender, strategy);
        // 获取策略的总份额
        uint256 strategyShares = getStrategy(strategy).totalShares();
        // 如果质押者份额或策略总份额为 0,返回 0
        if (stakerShare == 0 || strategyShares == 0) {
            return 0;
        }
        // 按比例计算奖励: 策略总奖励 * (质押者份额 / 策略总份额)
        return (stakerRewards[strategy] * stakerShare) / strategyShares;
    }

    /// @notice 更新运营商和质押者的收益分配比例
    /// @dev 修改质押者收益占比,运营商收益占比自动为 100 - stakerPercent
    /// @param _stakerPercent 新的质押者收益占比(0-100)
    function updateOperatorAndStakerShareFee(uint256 _stakerPercent) external {
        stakerPercent = _stakerPercent;
    }
}
