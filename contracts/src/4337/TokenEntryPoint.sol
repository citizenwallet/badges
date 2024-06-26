// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { ValidationData, _parseValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { SenderCreator } from "@account-abstraction/contracts/core/SenderCreator.sol";
import { UserOperation } from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import { IPaymaster } from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import { INonceManager } from "@account-abstraction/contracts/interfaces/INonceManager.sol";
import { UserOperationLib, UserOperation } from "@account-abstraction/contracts/interfaces/UserOperation.sol";

import { ITokenEntryPoint } from "./interfaces/ITokenEntryPoint.sol";

import { IUserOpValidator } from "./interfaces/IUserOpValidator.sol";

/**
 * @title TokenEntryPoint
 * @dev This contract is used to authorize user operations and execute them.
 * It inherits from Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, and UUPSUpgradeable.
 * It also uses ECDSA for signature verification and UserOperationLib for user operation handling.
 *
 * It is a simplified entry point contract.
 *
 * https://github.com/eth-infinitism/account-abstraction/blob/abff2aca61a8f0934e533d0d352978055fddbd96/contracts/core/EntryPoint.sol
 * https://github.com/eth-infinitism/account-abstraction/blob/abff2aca61a8f0934e533d0d352978055fddbd96/contracts/samples/VerifyingPaymaster.sol
 * https://github.com/eth-infinitism/account-abstraction/blob/abff2aca61a8f0934e533d0d352978055fddbd96/contracts/interfaces/UserOperation.sol
 */
contract TokenEntryPoint is
	ITokenEntryPoint,
	INonceManager,
	Initializable,
	ReentrancyGuardUpgradeable,
	OwnableUpgradeable,
	UUPSUpgradeable
{
	using ECDSA for bytes32;
	using UserOperationLib for UserOperation;

	SenderCreator private senderCreator;

	/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
	INonceManager private immutable _entrypoint;
	address private _paymaster;

	/// @custom:oz-upgrades-unsafe-allow constructor
	constructor(INonceManager anEntryPoint) {
		_entrypoint = anEntryPoint;
		_disableInitializers();
	}

	// we make the owner of also the sponsor by default
	function initialize(address anOwner, address aPaymaster, address[] calldata addresses) public virtual initializer {
		__Ownable_init(anOwner);
		__UUPSUpgradeable_init();
		__ReentrancyGuard_init();
		__Whitelist_init(addresses);

		_initialize(aPaymaster);
	}

	function _initialize(address aPaymaster) internal virtual {
		_paymaster = aPaymaster;
		senderCreator = new SenderCreator();

		executeSelector = bytes4(keccak256(bytes("execute(address,uint256,bytes)")));
		executeBatchSelector = bytes4(keccak256(bytes("executeBatch(address[],uint256[],bytes[])")));
	}

	mapping(address => mapping(uint192 => uint256)) public nonceSequenceNumber;

	function getNonce(address sender, uint192 key) public view override returns (uint256 nonce) {
		return _entrypoint.getNonce(sender, key);
	}

	function incrementNonce(uint192 key) external override onlyOwner {}

	// parse uint192 key from uint256 nonce
	function _parseNonce(uint256 nonce) internal pure returns (uint192 key, uint64 seq) {
		return (uint192(nonce >> 64), uint64(nonce));
	}

	function paymaster() public view returns (address) {
		return _paymaster;
	}

	function updatePaymaster(address newPaymaster) public onlyOwner {
		require(_contractExists(newPaymaster), "invalid paymaster");

		_paymaster = newPaymaster;
	}

	/**
	 * @dev Executes a batch of user operations.
	 * @param ops Array of UserOperation structs containing the operations to execute.
	 * @param beneficiary << kept to make sure we keep the same function signature.
	 * @notice This function is non-reentrant and requires at least one user operation.
	 * @notice Each operation is validated for nonce, account, and paymaster signature before execution.
	 */
	function handleOps(
		UserOperation[] calldata ops,
		address payable beneficiary // kept to make sure we keep the same function signature
	) public nonReentrant {
		(beneficiary);
		require(ops.length > 0, "AA42 needs at least one user operation");

		uint len = ops.length;
		for (uint i = 0; i < len; ) {
			// handle each op
			UserOperation calldata op = ops[i];

			address sender = op.getSender();

			(uint192 key, uint64 seq) = _parseNonce(op.nonce);

			// verify nonce
			_validateNonce(op, sender, key);

			// verify call data
			_validateCallData(op, sender);

			// verify account
			_validateAccount(op, sender, seq);

			// verify paymaster signature
			_validatePaymasterUserOp(op);

			// execute the op
			_call(sender, 0, op.callData);

			unchecked {
				++i;
			}
		}
	}

	/**
	 * @dev Validates the nonce of a user operation against the nonce stored in the account.
	 * @param op The user operation to validate.
	 * @param sender The address of the account to validate against.
	 * Requirements:
	 * - The nonce in the user operation must match the nonce in the account.
	 */
	function _validateNonce(UserOperation calldata op, address sender, uint192 key) internal virtual {
		uint256 nonce = getNonce(sender, key);

		// the nonce in the user op must match the nonce in the account
		require(nonce == op.nonce, "AA25 invalid account nonce");
	}

	/**
	 * @dev Validates a user operation and its signature.
	 * @param op The user operation to validate.
	 * @param sender The address of the sender of the user operation.
	 */
	function _validateAccount(UserOperation calldata op, address sender, uint64 seq) internal virtual {
		// call the initCode
		if (seq == 0 && !_contractExists(sender)) {
			_initAccount(op, sender);
		}

		// verify the user op signature
		IUserOpValidator account = IUserOpValidator(sender);

		require(account.validateUserOp(op, getUserOpHash(op)), "AA24 signature error");
	}

	/**
	 * @dev Initializes a new account using the provided UserOperation.
	 * @param op The UserOperation which contains the initCode.
	 */
	function _initAccount(UserOperation calldata op, address sender) internal virtual {
		bytes calldata initCode = op.initCode;

		// initCode must be at least 20 bytes long, and the first 20 bytes must be the factory address
		require(initCode.length >= 20, "AA17 invalid initCode");

		address factory = address(bytes20(initCode[0:20]));

		// the factory in the init code must be deployed
		require(_contractExists(factory), "AA16 invalid factory or does not exist");

		// call the factory
		address created = senderCreator.createSender(initCode);

		require(sender != address(0), "AA13 initCode failed or OOG");
		require(sender == created, "AA14 initCode must return sender");

		// the account must be created
		require(_contractExists(created), "AA15 initCode must create sender");
	}

	/**
	 * @dev Validates the paymaster address and data of a user operation.
	 * @param op The user operation to validate.
	 */
	function _validatePaymasterUserOp(UserOperation calldata op) internal virtual {
		address paymasterAddress = _getPaymaster(op);

		// verify paymasterAndData signature
		(, uint256 validationData) = IPaymaster(paymasterAddress).validatePaymasterUserOp(op, op.hash(), 0);

		address pmAggregator;
		bool outOfTimeRange;
		(pmAggregator, outOfTimeRange) = _getValidationData(validationData);
		if (pmAggregator != address(0)) {
			revert("AA34 signature error");
		}
		if (outOfTimeRange) {
			revert("AA32 paymaster expired or not due");
		}
	}

	function _getValidationData(
		uint256 validationData
	) internal view returns (address aggregator, bool outOfTimeRange) {
		if (validationData == 0) {
			return (address(0), false);
		}
		ValidationData memory data = _parseValidationData(validationData);
		// solhint-disable-next-line not-rely-on-time
		outOfTimeRange = block.timestamp > data.validUntil || block.timestamp < data.validAfter;
		aggregator = data.aggregator;
	}

	function _getPaymaster(UserOperation calldata op) internal virtual returns (address) {
		bytes calldata paymasterAndData = op.paymasterAndData;

		// paymasterAndData must be at least 20 bytes long, and the first 20 bytes must be the paymaster address
		require(paymasterAndData.length >= 20, "AA36 invalid paymaster data");

		address paymasterAddress = address(bytes20(paymasterAndData[0:20]));

		require(_contractExists(paymasterAddress), "AA30 paymaster not deployed");

		require(paymasterAddress == _paymaster, "AA35 invalid paymaster");

		return paymasterAddress;
	}

	bytes4 private executeSelector;
	bytes4 private executeBatchSelector;

	/**
	 * @dev Validates the call data in the user operation to make sure that only the functions we chose are allowed and that only whitelisted smart contracts can be called.
	 * @param op The user operation to validate.
	 */
	function _validateCallData(UserOperation calldata op, address sender) internal virtual {
		// callData must be at least 4 bytes long, and the first 4 bytes must be the function selector
		require(op.callData.length >= 4, "AA26 invalid calldata");

		bytes4 selector = bytes4(op.callData[0:4]);

		// the function selector must be valid
		require(selector != bytes4(0), "AA27 invalid function selector");

		// we only allow execute or executeBatch calls
		require(selector == executeSelector || selector == executeBatchSelector, "AA27 invalid function selector");

		if (selector == executeSelector) {
			address dest = _extractAddressFromCallData(op.callData);

			require(dest == sender || isWhitelisted(dest), "AA28 contract not whitelisted");
		}

		if (selector == executeBatchSelector) {
			address[] memory dests = _extractAddressesFromCallData(op.callData);

			for (uint i = 0; i < dests.length; i++) {
				// it should be possible to operate on your own contract without whitelisting it
				address dest = dests[i];

				require(dest == sender || isWhitelisted(dest), "AA28 contract not whitelisted");
			}
		}
	}

	/**
	 * @dev Extracts the address from the call data of a user operation.
	 * @param data The call data to extract the address from.
	 * @return An address.
	 */
	function _extractAddressFromCallData(bytes calldata data) internal pure returns (address) {
		// Decode the first argument as an address
		(address addr, , ) = abi.decode(data[4:data.length], (address, uint256, bytes));

		return addr;
	}

	/**
	 * @dev Extracts the addresses from the call data of a user operation.
	 * @param data The call data to extract the addresses from.
	 * @return An array of addresses.
	 */
	function _extractAddressesFromCallData(bytes calldata data) internal pure returns (address[] memory) {
		// Decode the first argument as an address
		(address[] memory addrs, , ) = abi.decode(data[4:data.length], (address[], uint256[], bytes[]));

		return addrs;
	}

	// more gas efficient for updating the whitelist than only using a mapping
	uint256 private _whitelistVersion;
	mapping(address => uint256) private _whitelist;

	function __Whitelist_init(address[] calldata addresses) internal initializer {
		_whitelistVersion = 0;
		_updateWhiteList(addresses);
	}

	/**
	 * @dev Checks if an address is in the whitelist.
	 * @param addr The address to check.
	 * @return A boolean indicating whether the address is in the whitelist.
	 */
	function isWhitelisted(address addr) internal view returns (bool) {
		return _whitelist[addr] == _whitelistVersion;
	}

	function _updateWhiteList(address[] calldata addresses) internal virtual {
		updateWhitelist(addresses);
	}

	/**
	 * @dev Updates the whitelist.
	 * @param addresses The addresses to update the whitelist.
	 */
	function updateWhitelist(address[] calldata addresses) public onlyOwner {
		// bump the version number so that we don't have to clear the mapping
		_whitelistVersion++;

		for (uint i = 0; i < addresses.length; i++) {
			_whitelist[addresses[i]] = _whitelistVersion;
		}
	}

	/**
	 * generate a request Id - unique identifier for this request.
	 * the request ID is a hash over the content of the userOp (except the signature), the entrypoint and the chainid.
	 */
	function getUserOpHash(UserOperation calldata userOp) public view returns (bytes32) {
		return keccak256(abi.encode(userOp.hash(), address(this), block.chainid));
	}

	/**
	 * @dev Checks if a contract exists at a given address.
	 * @param contractAddress The address to check.
	 * @return A boolean indicating whether a contract exists at the given address.
	 */
	function _contractExists(address contractAddress) internal virtual returns (bool) {
		uint size;
		assembly {
			size := extcodesize(contractAddress)
		}
		return size > 0;
	}

	/**
	 * @dev Internal function to call a contract with value and data.
	 * If the call fails, it reverts with the reason returned by the callee.
	 * @param target The address of the contract to call.
	 * @param value The amount of ether to send with the call.
	 * @param data The data to send with the call.
	 */
	function _call(address target, uint256 value, bytes memory data) internal {
		(bool success, bytes memory result) = target.call{ value: value }(data);
		if (!success) {
			assembly {
				revert(add(result, 32), mload(result))
			}
		}
	}

	function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
		(newImplementation);
	}
}
