// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";

import "../../interfaces/IScrollBridge.sol";
import "../../interfaces/IPolygonZkEVMBridge.sol";
import "../../interfaces/IArbitrumOneBridge.sol";
import "../../interfaces/IArbitrumNovaBridge.sol";
import "../../interfaces/IOptimismBridge.sol";
import "../../interfaces/IZksyncBridge.sol";
import "../../interfaces/IMantleBridge.sol";
import "../../interfaces/IMantaBridge.sol";
import "../../interfaces/WETH.sol";
import "../../interfaces/IL2PoolManager.sol";
import "../libraries/ContractsAddress.sol";
import "../bridge/TokenBridgeBase.sol";
import "../../interfaces/IMessageManager.sol";

/// @title L2PoolManager - L2 端的资金池管理合约
/// @notice 管理 L2 上的资产并处理从 L2 提款到 L1 的跨链操作
/// @dev 继承自 TokenBridgeBase 和 PausableUpgradeable,支持暂停功能
/// @dev 注意:当前的 Withdraw 函数依赖具体的链桥接口,需要重构为使用 MessageManager
contract L2PoolManager is IL2PoolManager, PausableUpgradeable, TokenBridgeBase {
    /// @notice 提款操作的最大 Gas 限制
    uint32 public MAX_GAS_Limit;

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化 L2PoolManager 合约
    /// @param _MultisigWallet 多签钱包地址,将被授予管理员角色
    /// @param _messageManager 消息管理器合约地址
    function initialize(
        address _MultisigWallet,
        address _messageManager
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        TokenBridgeBase.__TokenBridge_init(_MultisigWallet, _messageManager);
        MAX_GAS_Limit = 300000;
    }

    /* admin functions */
    /// @notice 从 L2 提款 ETH 到 L1
    /// @dev 【待重构】当前使用各链的官方桥合约,应改为使用 MessageManager 统一处理
    /// @dev 仅限 Relayer 角色调用
    /// @param _to L1 上的接收地址
    /// @param _amount 提款的 ETH 数量
    /// @return 是否成功发起提款
    function WithdrawETHtoL1(
        address _to,
        uint256 _amount
    ) external payable onlyRole(ReLayer) returns (bool) {
        uint256 Blockchain = block.chainid;
        if (_amount > address(this).balance) {
            revert NotEnoughETH();
        }
        if (Blockchain == 0x8274f) {
            //Scroll https://chainlist.org/chain/534352
            IScrollStandardL2ETHBridge(
                ContractsAddress.ScrollL2StandardETHBridge
            ).withdrawETH{gas: MAX_GAS_Limit, value: _amount}(
                _to,
                _amount,
                uint256(MAX_GAS_Limit)
            );
        }
            // else if (Blockchain == 0x5a2) {
            //     // Polygon zkEVM https://chainlist.org/chain/1101
            //     IPolygonZkEVML2Bridge(ContractsAddress.PolygonZkEVML2Bridge)
            //         .bridgeAsset{value: _amount}(
            //         0,
            //         _to,
            //         _amount,
            //         address(0),
            //         false,
            //         ""
            //     );
            // }
        else if (Blockchain == 0xaa37dc) {
            //OP Mainnet https://chainlist.org/chain/10
            IOptimismL2StandardBridge(ContractsAddress.OptimismL2StandardBridge)
            .withdrawTo{value: _amount}(
                ContractsAddress.OP_LEGACY_ERC20_ETH,
                _to,
                _amount,
                MAX_GAS_Limit,
                ""
            );
        } else if (Blockchain == 0x66eee) {
            // Arbitrum One https://chainlist.org/chain/42161
            IArbitrumOneL2ETHBridge(ContractsAddress.ArbitrumOneL2ETHBridge)
            .withdrawEth{value: _amount}(
                _to
            );
        }  else if (Blockchain == 0x14a34) {
            //Base sepolia
            IOptimismL2StandardBridge(ContractsAddress.BaseL2StandardBridge)
            .withdrawTo{value: _amount}(
                ContractsAddress.BASE_LEGACY_ERC20_ETH,
                _to,
                _amount,
                MAX_GAS_Limit,
                ""
            );
        }
            //No support for Arbitrum Nova
            //  else if (Blockchain == 0x12c) {
            //     //https://chainlist.org/chain/324
            //     //ZkSync Mainnet
            //     //https://github.com/zksync-sdk/zksync-ethers/blob/main/src/utils.ts#L92
            //     IZkSyncBridge(ContractsAddress.ZkSyncL2Bridge).withdraw{value: _amount}(
            //         _to,
            //         address(0),
            //         _amount
            //     );
            // }  else if (Blockchain == 0x138b) {
            //     //https://chainlist.org/chain/324
            //     //Mantle Mainnet
            //     IERC20(ContractsAddress.MantleETH).approve(
            //         ContractsAddress.MantleL2Bridge,
            //         _amount
            //     );
            //     IMantleL2Bridge(ContractsAddress.MantleL2Bridge).withdrawto(
            //         ContractsAddress.MantleETH,
            //         _to,
            //         _amount,
            //         MAX_GAS_Limit,
            //         ""
            //     );

            // } else if (Blockchain == 0x34816d) {
            //     //Manta Pacific Mainnet https://chainlist.org/chain/169
            //     IMantaL2Bridge(ContractsAddress.MantaL2Bridge)
            //         .withdrawTo{value: _amount}(
            //         ContractsAddress.OP_LEGACY_ERC20_ETH,
            //         _to,
            //         _amount,
            //         MAX_GAS_Limit,
            //         ""
            //     );
            // } else if (Blockchain == 0xab4b) {
            //     // ZKFair https://chainlist.org/chain/42766
            //     // ETH in ZKFair is ERC20
            //     IERC20(ContractsAddress.ZKFairETH).approve(
            //         ContractsAddress.ZKFairL2Bridge,
            //         _amount
            //     );
            //     IPolygonZkEVML2Bridge(ContractsAddress.ZKFairL2Bridge)
            //         .bridgeAsset(0, _to, _amount, ContractsAddress.ZKFairETH, false, "");
            // }
        else {
            revert ErrorBlockChain();
        }
        FundingPoolBalance[ContractsAddress.ETHAddress] -= _amount;
        emit WithdrawETHtoL1Success(
            block.chainid,
            block.timestamp,
            _to,
            _amount
        );
        return true;
    }

    /// @notice 从 L2 提款 WETH 到 L1
    /// @dev 【待重构】当前使用各链的官方桥合约,应改为使用 MessageManager 统一处理
    /// @dev 仅限 Relayer 角色调用
    /// @param _to L1 上的接收地址
    /// @param _amount 提款的 WETH 数量
    /// @return 是否成功发起提款
    function WithdrawWETHToL1(
        address _to,
        uint256 _amount
    ) external payable onlyRole(ReLayer) returns (bool) {
        uint256 Blockchain = block.chainid;
        IWETH WETH = IWETH(L2WETH());
        if (_amount > WETH.balanceOf(address(this))) {
            revert NotEnoughToken(address(WETH));
        }
        if (Blockchain == 0x8274f) {
            // Scroll https://chainlist.org/chain/534352
            WETH.approve(ContractsAddress.ScrollL2StandardWETHBridge, _amount);
            IScrollStandardL2WETHBridge(
                ContractsAddress.ScrollL2StandardWETHBridge
            ).withdrawERC20{gas: MAX_GAS_Limit}(
                address(WETH),
                _to,
                _amount,
                uint256(MAX_GAS_Limit)
            );
        }
            //  else if (Blockchain == 0x5a2) {
            //     // Polygon zkEVM https://chainlist.org/chain/1101
            //     WETH.approve(ContractsAddress.PolygonZkEVML2Bridge, _amount);
            //     IPolygonZkEVML2Bridge(ContractsAddress.PolygonZkEVML2Bridge)
            //         .bridgeAsset{value: _amount}(
            //         0,
            //         _to,
            //         _amount,
            //         address(0),
            //         false,
            //         ""
            //     );
            // }
        else if (Blockchain == 0xaa37dc) {
            // OP Mainnet https://chainlist.org/chain/10
            WETH.approve(ContractsAddress.OptimismL2StandardBridge, _amount);
            IOptimismL2StandardBridge(ContractsAddress.OptimismL2StandardBridge)
            .withdrawTo{value: _amount}(
                address(WETH),
                _to,
                _amount,
                MAX_GAS_Limit,
                ""
            );
        } else if (Blockchain == 0x66eee) {
            // Arbitrum One https://chainlist.org/chain/42161
            WETH.approve(ContractsAddress.ArbitrumOneL2WETHGateway, _amount);
            IArbitrumOneL2Bridge(ContractsAddress.ArbitrumOneL2WETHGateway)
            .outboundTransfer(ContractsAddress.WETH, _to, _amount, "");
        }
            // else if (Blockchain == 0x14a34) {
            //     // base sepolia
            //     WETH.approve(ContractsAddress.BaseL2StandardBridge, _amount);
            //     IOptimismL2StandardBridge(ContractsAddress.BaseL2StandardBridge)
            //         .withdrawTo{value: _amount}(
            //         address(WETH),
            //         _to,
            //         _amount,
            //         MAX_GAS_Limit,
            //         ""
            //     );
            // }
            // else if(Blockchain == 0x12c){
            //     //ZkSync Mainnet
            //     IZkSyncBridge(ContractsAddress.ZkSyncL2Bridge).withdraw{value: _amount}(
            //         _to,
            //         address(WETH),
            //         _amount
            //     );
            // }


        else {
            revert ErrorBlockChain();
        }
        emit WithdrawWETHtoL1Success(
            block.chainid,
            block.timestamp,
            _to,
            _amount
        );
        FundingPoolBalance[ContractsAddress.WETH] -= _amount;
        return true;
    }

    /// @notice 从 L2 提款 ERC20 代币到 L1
    /// @dev 【待重构】当前使用各链的官方桥合约,应改为使用 MessageManager 统一处理
    /// @dev 仅限 Relayer 角色调用
    /// @param _token ERC20 代币合约地址
    /// @param _to L1 上的接收地址
    /// @param _amount 提款的代币数量
    /// @return 是否成功发起提款
    function WithdrawERC20ToL1(
        address _token,
        address _to,
        uint256 _amount
    ) external payable onlyRole(ReLayer) returns (bool) {
        uint256 Blockchain = block.chainid;
        if (!IsSupportToken[_token]) {
            revert TokenIsNotSupported(_token);
        }
        if (Blockchain == 0x8274f) {
            //Scroll https://chainlist.org/chain/534352
            IERC20(_token).approve(
                ContractsAddress.ScrollL1StandardERC20Bridge,
                _amount
            );
            IScrollStandardL2ERC20Bridge(
                ContractsAddress.ScrollL1StandardERC20Bridge
            ).withdrawERC20{gas: MAX_GAS_Limit}(
                _token,
                _to,
                _amount,
                uint256(MAX_GAS_Limit)
            );
        }
            // else if (Blockchain == 0x5a2) {
            //     // Polygon zkEVM https://chainlist.org/chain/1101
            //     IERC20(_token).approve(
            //         ContractsAddress.PolygonZkEVML2Bridge,
            //         _amount
            //     );
            //     IPolygonZkEVML2Bridge(ContractsAddress.PolygonZkEVML2Bridge)
            //         .bridgeAsset(0, _to, _amount, _token, false, "");
            // }
        else if (Blockchain == 0xaa37dc) {
            //OP Mainnet https://chainlist.org/chain/10
            IERC20(_token).approve(
                ContractsAddress.OptimismL2StandardBridge,
                _amount
            );
            IOptimismL2StandardBridge(ContractsAddress.OptimismL2StandardBridge)
            .withdrawTo{value: _amount}(
                _token,
                _to,
                _amount,
                MAX_GAS_Limit,
                ""
            );
        } else if (Blockchain == 0x66eee) {
            // Arbitrum One https://chainlist.org/chain/42161
            IERC20(_token).approve(
                ContractsAddress.ArbitrumOneL2ERC20Gateway,
                _amount
            );
            IArbitrumOneL2Bridge(ContractsAddress.ArbitrumOneL2ERC20Gateway)
            .outboundTransfer(_token, _to, _amount, "");
        } else if (Blockchain == 0x14a34) {
            //OP Mainnet https://chainlist.org/chain/10
            IERC20(_token).approve(
                ContractsAddress.BaseL2StandardBridge,
                _amount
            );
            IOptimismL2StandardBridge(ContractsAddress.BaseL2StandardBridge)
            .withdrawTo{value: _amount}(
                _token,
                _to,
                _amount,
                MAX_GAS_Limit,
                ""
            );
        }
            // else if (Blockchain == 0x12c) {
            //     //ZkSync Mainnet https://chainlist.org/chain/324
            //     IZkSyncBridge(ContractsAddress.ZkSyncL2Bridge).withdraw{value: _amount}(
            //         _to,
            //         _token,
            //         _amount
            //     );
            // } else if (Blockchain == 0x138b) {
            //     //Mantle Mainnet
            //     IERC20(_token).approve(ContractsAddress.MantleL2Bridge, _amount);
            //     IMantleL2Bridge(ContractsAddress.MantleL2Bridge).withdrawto(
            //         _token,
            //         _to,
            //         _amount,
            //         MAX_GAS_Limit,
            //         ""
            //     );
            // }else if (Blockchain == 0x34816d) {
            //     //Manta Pacific Mainnet https://chainlist.org/chain/169
            //     IERC20(_token).approve(
            //         ContractsAddress.MantleL2Bridge,
            //         _amount
            //     );
            //     IMantaL2Bridge(ContractsAddress.MantleL2Bridge)
            //         .withdrawTo{value: _amount}(
            //         _token,
            //         _to,
            //         _amount,
            //         MAX_GAS_Limit,
            //         ""
            //     );
            // }
            // else if (Blockchain == 0xab4b) {
            //     // ZKFair https://chainlist.org/chain/42766
            //     IERC20(_token).approve(
            //         ContractsAddress.ZKFairL2Bridge,
            //         _amount
            //     );
            //     IPolygonZkEVML2Bridge(ContractsAddress.ZKFairL2Bridge)
            //         .bridgeAsset(0, _to, _amount, _token, false, "");
            // }
        else {
            revert ErrorBlockChain();
        }
        FundingPoolBalance[_token] -= _amount;
        emit WithdrawERC20toL1Success(
            block.chainid,
            block.timestamp,
            _token,
            _to,
            _amount
        );
        return true;
    }

    /// @notice 暂停合约的所有操作
    /// @dev 仅限管理员调用
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice 取消暂停合约的操作
    /// @dev 仅限管理员调用
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}