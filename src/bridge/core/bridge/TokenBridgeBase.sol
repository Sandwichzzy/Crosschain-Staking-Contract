// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../interfaces/IMessageManager.sol";
import "../libraries/ContractsAddress.sol";
import "../libraries/SafeCall.sol";
import "../../interfaces/WETH.sol";

abstract contract TokenBridgeBase is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard
{
    bytes32 public constant ReLayer =
    keccak256(abi.encode(uint256(keccak256("ReLayer")) - 1)) &
    ~bytes32(uint256(0xff));

    using SafeERC20 for IERC20;
    IMessageManager public messageManager;

    uint256 public MinTransferAmount;
    uint256 public PerFee; // 0.1%

    mapping(uint256 => bool) private IsSupportedChainId;
    mapping(address => bool) public IsSupportToken;
    mapping(address => uint256) public FundingPoolBalance;
    mapping(address => uint256) public FeePoolValue;
    address[] public SupportTokens;
    uint256 public stakingMessageNumber;

    event InitiateETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event InitiateWETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event InitiateERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed ERC20Address,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event InitiateStakingMessage(
        address indexed from,
        address indexed to,
        uint256 shares,
        uint256 stakeMessageNonce,
        bytes32 indexed stakeMessageHash
    );

    event FinalizeETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event FinalizeWETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event FinalizeERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed ERC20Address,
        address indexed from,
        address indexed to,
        uint256 value
    );

    event FinalizeStakingMessage(
        address indexed from,
        address indexed to,
        address shareAddress,
        uint256 shares,
        uint256 stakeMessageNonce,
        bytes32 stakeMessageHash
    );

    error ChainIdIsNotSupported(uint256 id);

    error ChainIdNotSupported(uint256 chainId);

    error TokenIsNotSupported(address ERC20Address);

    error NotEnoughToken(address ERC20Address);

    error NotEnoughETH();

    error ErrorBlockChain();

    error LessThanMinTransferAmount(uint256 MinTransferAmount, uint256 value);

    error sourceChainIdError();

    error sourceChainIsDestChainError();

    error MantleNotWETH();

    error MantaNotWETH();

    error TransferETHFailed();

    /// @notice 初始化 TokenBridge 基础合约
    /// @param _MultisigWallet 多签钱包地址,将被授予管理员角色
    /// @param _messageManager 消息管理器合约地址,用于跨链消息传递
    function __TokenBridge_init(
        address _MultisigWallet,
        address _messageManager
    ) internal onlyInitializing {
        MinTransferAmount = 0.1 ether;
        PerFee = 10000; // 1%
        _grantRole(DEFAULT_ADMIN_ROLE, _MultisigWallet);
        messageManager = IMessageManager(_messageManager);
        stakingMessageNumber = 1;
    }

    /// @notice 发起 ETH 的跨链转账
    /// @dev 用户在源链调用此函数,发送 ETH 到目标链
    /// @param sourceChainId 源链 ID,必须与当前链 ID 一致
    /// @param destChainId 目标链 ID,必须在支持的链列表中
    /// @param to 目标链上的接收地址
    /// @return 是否成功发起跨链转账
    function BridgeInitiateETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address to
    ) external payable returns (bool) {
        if (sourceChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(destChainId)) {
            revert ChainIdIsNotSupported(destChainId);
        }
        if (msg.value < MinTransferAmount) {
            revert LessThanMinTransferAmount(MinTransferAmount, msg.value);
        }
        FundingPoolBalance[ContractsAddress.ETHAddress] += msg.value;

        uint256 fee = (msg.value * PerFee) / 1_000_000;
        uint256 amount = msg.value - fee;
        FeePoolValue[ContractsAddress.ETHAddress] += fee;

        messageManager.sendMessage(block.chainid, destChainId, to, amount, fee);

        emit InitiateETH(sourceChainId, destChainId, msg.sender, to, amount);
        return true;
    }

    /// @notice 发起 WETH 的跨链转账
    /// @dev 从用户账户转移 WETH 到本合约,然后通过 MessageManager 发送跨链消息
    /// @param sourceChainId 源链 ID,必须与当前链 ID 一致
    /// @param destChainId 目标链 ID,不能与源链相同
    /// @param to 目标链上的接收地址
    /// @param value 转账的 WETH 数量
    /// @return 是否成功发起跨链转账
    function BridgeInitiateWETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address to,
        uint256 value
    ) external returns (bool) {
        if (sourceChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if(sourceChainId == destChainId){
            revert sourceChainIsDestChainError();
        }
        if (!IsSupportChainId(destChainId)) {
            revert ChainIdNotSupported(destChainId);
        }

        IWETH WETH = IWETH(L2WETH());

        uint256 BalanceBefore = WETH.balanceOf(address(this));
        WETH.transferFrom(msg.sender, address(this), value);
        uint256 BalanceAfter = WETH.balanceOf(address(this));
        uint256 amount = BalanceAfter - BalanceBefore;
        if (amount < MinTransferAmount) {
            revert LessThanMinTransferAmount(MinTransferAmount, amount);
        }
        FundingPoolBalance[ContractsAddress.WETH] += amount;

        uint256 fee = (amount * PerFee) / 1_000_000;
        amount -= fee;
        FeePoolValue[ContractsAddress.WETH] += fee;

        messageManager.sendMessage(sourceChainId, destChainId, to, amount, fee);

        emit InitiateWETH(sourceChainId, destChainId, msg.sender, to, amount);

        return true;
    }

    /// @notice 发起 ERC20 代币的跨链转账
    /// @dev 从用户账户转移 ERC20 到本合约,扣除手续费后通过 MessageManager 发送跨链消息
    /// @param sourceChainId 源链 ID,必须与当前链 ID 一致
    /// @param destChainId 目标链 ID,必须在支持的链列表中
    /// @param to 目标链上的接收地址
    /// @param ERC20Address ERC20 代币合约地址,必须在支持的代币列表中
    /// @param value 转账的代币数量
    /// @return 是否成功发起跨链转账
    function BridgeInitiateERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address to,
        address ERC20Address,
        uint256 value
    ) external returns (bool) {
        if (sourceChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(destChainId)) {
            revert ChainIdIsNotSupported(destChainId);
        }
        if (!IsSupportToken[ERC20Address]) {
            revert TokenIsNotSupported(ERC20Address);
        }

        uint256 BalanceBefore = IERC20(ERC20Address).balanceOf(address(this));
        IERC20(ERC20Address).safeTransferFrom(msg.sender, address(this), value);
        uint256 BalanceAfter = IERC20(ERC20Address).balanceOf(address(this));
        uint256 amount = BalanceAfter - BalanceBefore;
        FundingPoolBalance[ERC20Address] += value;
        uint256 fee = (amount * PerFee) / 1_000_000;
        amount -= fee;
        FeePoolValue[ERC20Address] += fee;

        messageManager.sendMessage(sourceChainId, destChainId, to, amount, fee);

        emit InitiateERC20(
            sourceChainId,
            destChainId,
            ERC20Address,
            msg.sender,
            to,
            amount
        );

        return true;
    }

    /// @notice 发起质押消息的跨链传递
    /// @dev 生成质押消息哈希并发出事件,用于跨链质押份额的转移
    /// @param from 份额的原始持有者地址
    /// @param to 份额的目标接收者地址
    /// @param shares 转移的份额数量
    /// @return 是否成功发起质押消息
    function BridgeInitiateStakingMessage(
        address from,
        address to,
        uint256 shares
    ) external returns (bool) {
        bytes32 stakingMessageHash = keccak256(
            abi.encode(from, to, shares, stakingMessageNumber)
        );
        emit InitiateStakingMessage(
            from,
            to,
            shares,
            stakingMessageNumber,
            stakingMessageHash
        );
        stakingMessageNumber++;
        return true;
    }

    /// @notice 在目标链完成 ETH 的跨链接收
    /// @dev 由 Relayer 调用,验证跨链消息后将 ETH 转给接收者
    /// @param sourceChainId 源链 ID,必须在支持的链列表中
    /// @param destChainId 目标链 ID,必须与当前链 ID 一致
    /// @param to 接收者地址
    /// @param amount 接收的 ETH 数量(已扣除手续费)
    /// @param _fee 手续费金额
    /// @param _nonce 消息序号,用于防止重放攻击
    /// @return 是否成功完成跨链接收
    function BridgeFinalizeETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address to,
        uint256 amount,
        uint256 _fee,
        uint256 _nonce
    ) external payable onlyRole(ReLayer) returns (bool) {
        if (destChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(sourceChainId)) {
            revert ChainIdIsNotSupported(sourceChainId);
        }
//        转移 ETH 到目标地址 (StakingManager)
        (bool _ret, ) = payable(to).call{value: amount}("");
        if (!_ret) {
            revert TransferETHFailed();
        }
        //减少资金池余额
        FundingPoolBalance[ContractsAddress.ETHAddress] -= amount;

        //调用 MessageManager 标记消息已认领
        messageManager.claimMessage(
            sourceChainId,
            destChainId,
            to,
            _fee,
            amount,
            _nonce
        );

        emit FinalizeETH(sourceChainId, destChainId, address(this), to, amount);
        return true;
    }

    /// @notice 在目标链完成 WETH 的跨链接收
    /// @dev 由 Relayer 调用,验证跨链消息后将 WETH 转给接收者
    /// @param sourceChainId 源链 ID,必须在支持的链列表中
    /// @param destChainId 目标链 ID,必须与当前链 ID 一致
    /// @param to 接收者地址
    /// @param amount 接收的 WETH 数量(已扣除手续费)
    /// @param _fee 手续费金额
    /// @param _nonce 消息序号,用于防止重放攻击
    /// @return 是否成功完成跨链接收
    function BridgeFinalizeWETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address to,
        uint256 amount,
        uint256 _fee,
        uint256 _nonce
    ) external onlyRole(ReLayer) returns (bool) {
        if (destChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(sourceChainId)) {
            revert ChainIdIsNotSupported(sourceChainId);
        }

        IWETH WETH = IWETH(L2WETH());
        WETH.transfer(to, amount);
        FundingPoolBalance[ContractsAddress.WETH] -= amount;

        messageManager.claimMessage(
            sourceChainId,
            destChainId,
            to,
            _fee,
            amount,
            _nonce
        );

        emit FinalizeWETH(
            sourceChainId,
            destChainId,
            address(this),
            to,
            amount
        );
        return true;
    }

    /// @notice 在目标链完成 ERC20 代币的跨链接收
    /// @dev 由 Relayer 调用,验证跨链消息后将 ERC20 代币转给接收者
    /// @param sourceChainId 源链 ID,必须在支持的链列表中
    /// @param destChainId 目标链 ID,必须与当前链 ID 一致
    /// @param to 接收者地址
    /// @param ERC20Address ERC20 代币合约地址,必须在支持的代币列表中
    /// @param amount 接收的代币数量(已扣除手续费)
    /// @param _fee 手续费金额
    /// @param _nonce 消息序号,用于防止重放攻击
    /// @return 是否成功完成跨链接收
    function BridgeFinalizeERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address to,
        address ERC20Address,
        uint256 amount,
        uint256 _fee,
        uint256 _nonce
    ) external onlyRole(ReLayer) returns (bool) {
        if (destChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(sourceChainId)) {
            revert ChainIdIsNotSupported(sourceChainId);
        }
        if (!IsSupportToken[ERC20Address]) {
            revert TokenIsNotSupported(ERC20Address);
        }
        IERC20(ERC20Address).safeTransfer(to, amount);
        FundingPoolBalance[ERC20Address] -= amount;

        messageManager.claimMessage(
            sourceChainId,
            destChainId,
            to,
            _fee,
            amount,
            _nonce
        );

        emit FinalizeERC20(
            sourceChainId,
            destChainId,
            ERC20Address,
            address(this),
            to,
            amount
        );
        return true;
    }

    /// @notice 在目标链完成质押份额的跨链转移
    /// @dev 通过安全调用目标合约的 TransferShareTo 函数来转移质押份额
    /// @param shareAddress 份额管理合约地址
    /// @param from 份额的原始持有者地址
    /// @param to 份额的目标接收者地址
    /// @param shares 转移的份额数量
    /// @param stakeMessageNonce 质押消息序号
    /// @param gasLimit 调用的 gas 限制
    /// @return 是否成功完成份额转移
    function BridgeFinalizeStakingMessage(
        address shareAddress,
        address from,
        address to,
        uint256 shares,
        uint256 stakeMessageNonce,
        uint256 gasLimit
    ) external returns (bool) {
        bytes32 stakingMessageHash = keccak256(
            abi.encode(from, to, shares, stakeMessageNonce)
        );
        bool success = SafeCall.callWithMinGas(
            shareAddress,
            gasLimit,
            0,
            abi.encodeWithSignature(
                "TransferShareTo(address,address,uint256,uint256)",
                from,
                to,
                shares,
                stakeMessageNonce
            )
        );
        require(
            success,
            "TokenBridge.BridgeFinalizeStakingMessage: call failed"
        );
        emit FinalizeStakingMessage(
            from,
            to,
            shareAddress,
            shares,
            stakeMessageNonce,
            stakingMessageHash
        );
        return true;
    }

    /// @notice 检查给定的链 ID 是否在支持的链列表中
    /// @param chainId 要检查的链 ID
    /// @return 是否支持该链
    function IsSupportChainId(uint256 chainId) public view returns (bool) {
        return IsSupportedChainId[chainId];
    }

    /// @notice 根据当前链 ID 返回对应的 WETH 合约地址
    /// @dev 支持 Scroll、Arbitrum、Base 等多条链
    /// @return WETH 合约地址
    function L2WETH() public view returns (address) {
        uint256 Blockchain = block.chainid;
        if (Blockchain == 0x82750) {
            // Scroll: https://chainlist.org/chain/534352
            return (ContractsAddress.ScrollWETH);
        } else if (Blockchain == 0xa4b1) {
            // Arbitrum One https://chainlist.org/chain/42161
            return (ContractsAddress.ArbitrumOneWETH);
        } else if (Blockchain == 0x1388) {
            //Mantle https://chainlist.org/chain/5000
            revert MantleNotWETH();
        } else if (Blockchain == 0xa9) {
            //Manta Pacific Mainnet https://chainlist.org/chain/169
            revert MantaNotWETH();
        } else if (Blockchain == 0x2105) {
            // basechain https://chainlist.org/chain/2105
            return (ContractsAddress.BaseWETH);
        } else {
            revert ErrorBlockChain();
        }
    }

    /// @notice 快速向用户发送资产,由 Relayer 调用
    /// @dev 这是 SendAssertToUser 的外部可调用版本
    /// @param _token 代币地址(ETH 使用 ETHAddress)
    /// @param to 接收者地址
    /// @param _amount 发送数量
    function QuickSendAssertToUser(
        address _token,
        address to,
        uint256 _amount
    ) external onlyRole(ReLayer) {
        SendAssertToUser(_token, to, _amount);
    }

    /// @notice 内部函数:向用户发送资产(ETH 或 ERC20)
    /// @dev 从 FundingPoolBalance 中扣除并转账给用户
    /// @param _token 代币地址(ETH 使用 ETHAddress)
    /// @param to 接收者地址
    /// @param _amount 发送数量
    /// @return 是否成功发送
    function SendAssertToUser(
        address _token,
        address to,
        uint256 _amount
    ) internal returns (bool) {
        if (!IsSupportToken[_token]) {
            revert TokenIsNotSupported(_token);
        }
        require((FundingPoolBalance[_token]>=_amount),"Not enough balance");
        FundingPoolBalance[_token] -= _amount;
        if (_token == address(ContractsAddress.ETHAddress)) {
            if (address(this).balance < _amount) {
                revert NotEnoughETH();
            }
            (bool _ret, ) = payable(to).call{value: _amount}("");
            if (!_ret) {
                revert TransferETHFailed();
            }
        } else {
            if (IERC20(_token).balanceOf(address(this)) < _amount) {
                revert NotEnoughToken(_token);
            }
            IERC20(_token).safeTransfer(to, _amount);
        }
        return true;
    }

    /// @notice 设置最小转账金额
    /// @param _MinTransferAmount 最小转账金额(wei)
    function setMinTransferAmount(
        uint256 _MinTransferAmount
    ) external onlyRole(ReLayer) {
        MinTransferAmount = _MinTransferAmount;
    }

    /// @notice 设置链是否被支持
    /// @param chainId 链 ID
    /// @param isValid 是否支持该链
    function setValidChainId(
        uint256 chainId,
        bool isValid
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IsSupportedChainId[chainId] = isValid;
    }

    /// @notice 设置是否支持某个 ERC20 代币
    /// @param ERC20Address ERC20 代币合约地址
    /// @param isValid 是否支持该代币
    function setSupportERC20Token(
        address ERC20Address,
        bool isValid
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IsSupportToken[ERC20Address] = isValid;
        if (isValid) {
            SupportTokens.push(ERC20Address);
        }
    }

    /// @notice 设置跨链转账手续费比例
    /// @param _PerFee 手续费比例(基点,例如 10000 = 1%)
    function setPerFee(uint256 _PerFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_PerFee<1_000_000);
        PerFee = _PerFee;
    }

    /// @notice 设置资金池余额(仅限紧急情况)
    /// @param token 代币地址
    /// @param amount 余额数量
    function setFundingPoolBalance(
        address token,
        uint256 amount
    ) external onlyRole(ReLayer) {
        FundingPoolBalance[token] = amount;
    }
}