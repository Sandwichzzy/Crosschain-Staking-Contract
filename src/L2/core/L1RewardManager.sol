// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;


import {L2Base} from "./L2Base.sol";
import "../interfaces/IStrategyManager.sol";
import "../interfaces/IL1RewardManager.sol";

/// @title L1RewardManager - L1 层收益管理合约(部署在 L2)
/// @notice 管理从 L1 层桥接过来的 ETH 质押收益,按照用户在策略中的份额分配给质押者
/// @dev 虽然名为 L1RewardManager,但实际部署在 L2 上,用于接收和分配 L1 的质押奖励
contract L1RewardManager is IL1RewardManager, L2Base{
    /// @notice L1 收益余额,记录从 L1 桥接过来的 ETH 总量
    uint256 public L1RewardBalance;

//    /// @notice 分配对象结构体(暂未使用)
//    struct AllocateObj {
//        StrategyObj[] strategies;
//    }
//
//    /// @notice 策略对象结构体(暂未使用)
//    struct StrategyObj {
//        address strategy;
//        OperatorObj[] operators;
//    }
//
//    /// @notice 运营商对象结构体(暂未使用)
//    struct OperatorObj {
//        address strategy;
//        StakerObj[] stakers;
//    }
//
//    /// @notice 质押者对象结构体(暂未使用)
//    struct StakerObj {
//        address staker;
//        uint256 share;
//    }

//    /// @notice 记录每个质押者在特定策略和运营商下的奖励
//    /// @dev mapping(质押者 => mapping(策略 => mapping(运营商 => 奖励金额)))
//    mapping(address => mapping(address => mapping (address => uint256) )) public stakerStrategyOperatorReward;

    constructor(){
        _disableInitializers();
    }

    /// @notice 初始化 L1 奖励管理合约
    /// @param initialOwner 初始所有者地址
    function initialize(
        address initialOwner
    ) external initializer {
        __L2Base_init(initialOwner);
    }

    /// @notice 接收从 L1 桥接过来的 ETH 奖励
    /// @dev 桥接合约调用此函数存入 L1 质押收益
    /// @return 是否成功
    function depositETHRewardTo() external payable returns (bool) {
        payable(address(this)).transfer(msg.value);
        L1RewardBalance += msg.value;
        emit DepositETHRewardTo(msg.sender, msg.value);
        return true;
    }

    /// @notice 质押者申领 L1 奖励
    /// @dev 根据用户在多个策略中的份额比例计算并发送奖励
    /// @param _strategies 质押者参与的策略地址数组
    /// @return 是否成功
    function claimL1Reward(address[] calldata _strategies) external payable returns (bool) {
        uint256 amountToSend = stakerRewardsAmount(_strategies);
        payable(msg.sender).transfer(amountToSend);
        emit ClaimL1Reward(msg.sender, amountToSend);
        return true;
    }

    // /// @notice 分配 L1 奖励(已注释,暂未实现)
    // /// @dev 预留函数,用于将奖励按照策略、运营商、质押者层级分配
    // /// @param _allocateObj 分配对象,包含策略、运营商、质押者的层级结构
    // function allocateL1Reward(AllocateObj calldata _allocateObj)external onlyRelayer{
    //     uint256 totalShares = 0;
    //     for (uint256 i = 0; i < _allocateObj.strategies.length; i++) {
    //         IStrategy _strategy = getStrategy(_allocateObj.strategies[i].strategy);
    //
    //         totalShares += _strategies[i].totalShares();
    //         // userShares += _strategies[i].shares(msg.sender);
    //     }
    //
    //     for (uint256 i = 0; i < _allocateObj.strategies.length; i++) {
    //         IStrategy _strategy = getStrategy(_allocateObj.strategies[i]);
    //
    //         totalShares += _strategies[i].totalShares();
    //         // userShares += _strategies[i].shares(msg.sender);
    //     }
    // }


    /// @notice 计算质押者在指定策略中可获得的奖励金额
    /// @dev 根据用户份额占总份额的比例计算奖励: L1RewardBalance * (用户份额 / 总份额)
    /// @param _strategies 策略地址数组
    /// @return 质押者可获得的奖励金额
    function stakerRewardsAmount(address[] calldata _strategies) public view returns (uint256) {
        uint256 totalShares = 0;
        uint256 userShares = 0;
        // 遍历所有策略,累加总份额和用户份额
        for (uint256 i = 0; i < _strategies.length; i++) {
            totalShares += getStrategy(_strategies[i]).totalShares();
            userShares += getStrategy(_strategies[i]).shares(msg.sender);
        }
        // 如果总份额或用户份额为 0,返回 0
        if (totalShares == 0 || userShares == 0) {
            return 0;
        }
        // 按比例计算奖励
        return L1RewardBalance * (userShares / totalShares);
    }



}
