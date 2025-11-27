// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

//EIP-1271 使得智能合约可以像外部账户一样进行签名验证(合约钱包)
library EIP1271SignatureUtils {
    bytes4 internal constant EIP1271_MAGICVALUE = 0x1626ba7e; // EIP-1271 标准定义的成功返回值

    /**
     * @dev 检查签名是否有效，支持 EOA 和合约签名（EIP-1271）
     * @param signer 签名者地址
     * @param digestHash 消息摘要哈希
     * @param signature 签名数据
     */
    function checkSignature_EIP1271(address signer, bytes32 digestHash, bytes memory signature) internal view {
        if (_isContract(signer)) {
            require(
                IERC1271(signer).isValidSignature(digestHash, signature) == EIP1271_MAGICVALUE,
                "EIP1271SignatureUtils.checkSignature_EIP1271: ERC1271 signature verification failed"
            );
        } else {
            require(
                ECDSA.recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digestHash)), signature)
                    == signer,
                "EIP1271SignatureUtils.checkSignature_EIP1271: signature not from signer"
            );
        }
    }

    /**
     * @dev 检查地址是否为合约
     * @param account 地址
     * @return bool 是否为合约地址
     */
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0; // EOA 的 code.length 为 0，合约地址的 code.length 大于 0
    }
}
