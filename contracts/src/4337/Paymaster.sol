// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/* solhint-disable reason-string */
/* solhint-disable no-inline-assembly */

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { _packValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { IPaymaster } from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import { INonceManager } from "@account-abstraction/contracts/interfaces/INonceManager.sol";
import { UserOperationLib, UserOperation } from "@account-abstraction/contracts/interfaces/UserOperation.sol";

/**
 * A sample paymaster that uses external service to decide whether to pay for the UserOp.
 * The paymaster trusts an external signer to sign the transaction.
 * The calling user must pass the UserOp to that external signer first, which performs
 * whatever off-chain verification before signing the UserOp.
 * Note that this signature is NOT a replacement for the account-specific signature:
 * - the paymaster checks a signature to agree to PAY for GAS.
 * - the account checks a signature to prove identity and account ownership.
 *
 *  https://github.com/eth-infinitism/account-abstraction/blob/abff2aca61a8f0934e533d0d352978055fddbd96/contracts/samples/VerifyingPaymaster.sol
 */
contract Paymaster is IPaymaster, Initializable, OwnableUpgradeable, UUPSUpgradeable {
	using ECDSA for bytes32;
	using UserOperationLib for UserOperation;

	uint256 private constant VALID_TIMESTAMP_OFFSET = 20;

	uint256 private constant SIGNATURE_OFFSET = 84;

	/// @custom:oz-upgrades-unsafe-allow constructor
	constructor() {
		_disableInitializers();
	}

	function initialize(address _owner, address aSponsor) public virtual initializer {
		__Ownable_init(_owner);

		_initialize(aSponsor);
	}

	function _initialize(address aSponsor) internal virtual {
		_sponsor = aSponsor;

		executeSelector = bytes4(keccak256(bytes("execute(address,uint256,bytes)")));
		executeBatchSelector = bytes4(keccak256(bytes("executeBatch(address[],uint256[],bytes[])")));
	}

	////////////////////////////////////////////////
	// separate the owner from the one who will actually sign the transactions.
	address private _sponsor;

	function sponsor() public view returns (address) {
		return _sponsor;
	}

	function updateSponsor(address newSponsor) public onlyOwner {
		_sponsor = newSponsor;
	}

	////////////////////////////////////////////////

	bytes4 private executeSelector;
	bytes4 private executeBatchSelector;

	function pack(UserOperation calldata userOp) internal pure returns (bytes memory ret) {
		// lighter signature scheme. must match UserOp.ts#packUserOp
		address sender = userOp.getSender();

		uint256 nonce = userOp.nonce;

		// we only allow execute or executeBatch calls
		bytes4 selector = bytes4(userOp.callData[0:4]);

		return abi.encode(sender, nonce, selector);
	}

	/**
	 * return the hash we're going to sign off-chain (and validate on-chain)
	 * this method is called by the off-chain service, to sign the request.
	 * it is called on-chain from the validatePaymasterUserOp, to validate the signature.
	 * note that this signature covers all fields of the UserOperation, except the "paymasterAndData",
	 * which will carry the signature itself.
	 */
	function getHash(
		UserOperation calldata userOp,
		uint48 validUntil,
		uint48 validAfter
	) public view returns (bytes32) {
		// can't use userOp.hash(), since it contains also the paymasterAndData itself.

		bytes4 selector = bytes4(userOp.callData[0:4]);

		// the function selector must be valid
		require(selector != bytes4(0), "AA27 invalid function selector");

		// we only allow execute or executeBatch calls
		require(selector == executeSelector || selector == executeBatchSelector, "AA27 invalid function selector");

		return keccak256(abi.encode(pack(userOp), block.chainid, address(this), sponsor(), validUntil, validAfter));
	}

	/**
	 * verify our external signer signed this request.
	 * the "paymasterAndData" is expected to be the paymaster and a signature over the entire request params
	 * paymasterAndData[:20] : address(this)
	 * paymasterAndData[20:84] : abi.encode(validUntil, validAfter)
	 * paymasterAndData[84:] : signature
	 */
	function validatePaymasterUserOp(
		UserOperation calldata userOp,
		bytes32 userOpHash,
		uint256 maxCost
	) public view returns (bytes memory context, uint256 validationData) {
		(userOpHash);
		(maxCost);
		(uint48 validUntil, uint48 validAfter, bytes calldata signature) = _parsePaymasterAndData(
			userOp.paymasterAndData
		);
		// ECDSA library supports both 64 and 65-byte long signatures.
		// we only "require" it here so that the revert reason on invalid signature will be of "VerifyingPaymaster", and not "ECDSA"
		require(signature.length == 64 || signature.length == 65, "AA35 invalid signature length");

		uint48 currentTime = uint48(block.timestamp);
		require(currentTime >= validAfter, "AA32 expired or not due");
		require(currentTime < validUntil, "AA32 expired or not due");

		bytes32 hash = getHash(userOp, validUntil, validAfter);
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(hash);

		if (sponsor() != signedHash.recover(signature)) {
			return ("", _packValidationData(true, validUntil, validAfter));
		}

		return ("", _packValidationData(false, validUntil, validAfter));
	}

	function _parsePaymasterAndData(
		bytes calldata paymasterAndData
	) internal pure returns (uint48 validUntil, uint48 validAfter, bytes calldata signature) {
		(validUntil, validAfter) = abi.decode(
			paymasterAndData[VALID_TIMESTAMP_OFFSET:SIGNATURE_OFFSET],
			(uint48, uint48)
		);
		signature = paymasterAndData[SIGNATURE_OFFSET:];
	}

	function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) external view {}

	function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
		(newImplementation);
	}
}
