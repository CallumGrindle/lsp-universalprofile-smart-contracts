// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.6;

// modules
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// interfaces
import "../../submodules/ERC725/implementations/contracts/ERC725/ERC725Y.sol";
import "../../submodules/ERC725/implementations/contracts/IERC1271.sol";

// libraries
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../Utils/ERC725Utils.sol";

/**
 * @title Contract acting as a controller of an ERC725 Account, using permissions stored in the ERC725Y storage
 * @author Fabian Vogelsteller, Jean Cavallera
 * @dev all the permissions can be set on the ERC725 Account using `setData(...)` with the keys constants below
 */
contract KeyManagerInit is Initializable, ERC165, IERC1271 {
    using ECDSA for bytes32;
    using SafeMath for uint256;
    using ERC725Utils for ERC725Y;

    ERC725Y public account;
    mapping(address => mapping(uint256 => uint256)) internal _nonceStore;

    bytes4 internal constant _INTERFACE_ID_ERC1271 = 0x1626ba7e;
    bytes4 internal constant _ERC1271FAILVALUE = 0xffffffff;

    // prettier-ignore
    /* solhint-disable */
    // PERMISSION KEYS
    bytes8 internal constant _SET_PERMISSIONS       = 0x4b80742d00000000;         // AddressPermissions:<...>
    bytes12 internal constant _KEY_PERMISSIONS      = 0x4b80742d0000000082ac0000; // AddressPermissions:Permissions:<address> --> bytes1
    bytes12 internal constant _KEY_ALLOWEDADDRESSES = 0x4b80742d00000000c6dd0000; // AddressPermissions:AllowedAddresses:<address> --> address[]
    bytes12 internal constant _KEY_ALLOWEDFUNCTIONS = 0x4b80742d000000008efe0000; // AddressPermissions:AllowedFunctions:<address> --> bytes4[]
    bytes12 internal constant _KEY_ALLOWEDSTANDARDS = 0x4b80742d000000003efa0000; // AddressPermissions:AllowedStandards:<address> --> bytes4[]
    /* solhint-enable */

    // prettier-ignore
    // PERMISSIONS VALUES
    bytes1 internal constant _PERMISSION_CHANGEOWNER   = 0x01;   // 0000 0001
    bytes1 internal constant _PERMISSION_CHANGEKEYS    = 0x02;   // 0000 0010
    bytes1 internal constant _PERMISSION_SETDATA       = 0x04;   // 0000 0100
    bytes1 internal constant _PERMISSION_CALL          = 0x08;   // 0000 1000
    bytes1 internal constant _PERMISSION_DELEGATECALL  = 0x10;   // 0001 0000
    bytes1 internal constant _PERMISSION_DEPLOY        = 0x20;   // 0010 0000
    bytes1 internal constant _PERMISSION_TRANSFERVALUE = 0x40;   // 0100 0000
    bytes1 internal constant _PERMISSION_SIGN          = 0x80;   // 1000 0000

    // selectors
    bytes4 internal constant _SETDATA_SELECTOR = 0x7f23690c;
    bytes4 internal constant _EXECUTE_SELECTOR = 0x44c028fe;
    bytes4 internal constant _TRANSFEROWNERSHIP_SELECTOR = 0xf2fde38b;

    event Executed(uint256 indexed _value, bytes _data);

    function initialize(address _account) public initializer {
        account = ERC725Y(_account);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165)
        returns (bool)
    {
        return
            interfaceId == _INTERFACE_ID_ERC1271 ||
            super.supportsInterface(interfaceId);
    }

    /**
     * Get latest nonce for `_from` in a specific channel (`_channelId`)
     *
     * @param _from caller address
     * @param _channelId channel id
     */
    function getNonce(address _from, uint128 _channelId) public view returns (uint256) {
        uint128 nonceId = uint128(_nonceStore[_from][_channelId]);
        return uint256(_channelId) << 128 | nonceId;
    }

    /**
     * @dev "idx" is a 256bits (unsigned) integer, where:
     *          - the 128 leftmost bits = channelId
     *      and - the 128 rightmost bits = nonce within the channel
     * @param _from caller address
     * @param _idx (channel id + nonce within the channel)
     */
    function _verifyNonce(address _from, uint256 _idx) 
        internal 
        view 
        returns (bool) 
    {
        // idx % (1 << 128) = nonce
        // (idx >> 128) = channel
        // equivalent to: return (nonce == _nonceStore[_from][channel]
        return (_idx % (1 << 128)) == (_nonceStore[_from][_idx >> 128]);
    }

    /**
     * @notice Checks if an owner signed `_data`.
     * ERC1271 interface.
     *
     * @param _hash hash of the data signed//Arbitrary length data signed on the behalf of address(this)
     * @param _signature owner's signature(s) of the data
     */
    function isValidSignature(bytes32 _hash, bytes memory _signature)
        public
        view
        override
        returns (bytes4 magicValue)
    {
        address recoveredAddress = ECDSA.recover(_hash, _signature);
        return (_PERMISSION_SIGN & _getUserPermissions(recoveredAddress)) == _PERMISSION_SIGN ? _INTERFACE_ID_ERC1271 : _ERC1271FAILVALUE;
    }

    /**
     * @dev execute the payload _data on the ERC725 Account
     * @param _data obtained via encodeABI() in web3
     * @return success_ true if the call on ERC725 Account succeeded, false otherwise
     */
    function execute(bytes calldata _data)
        external
        payable
        returns (bool success_)
    {
        _checkPermissions(msg.sender, _data);
        (success_, ) = address(account).call{value: msg.value, gas: gasleft()}(
            _data
        );
        if (success_) emit Executed(msg.value, _data);
    }

    /**
     * @dev allows anybody to execute given they have a signed message from an executor
     * @param _data obtained via encodeABI() in web3
     * @param _signedFor this KeyManager
     * @param _nonce the address' nonce (in a specific `_channel`), obtained via `getNonce(...)`. Used to prevent replay attack
     * @param _signature bytes32 ethereum signature
     */
    function executeRelayCall(
        bytes calldata _data,
        address _signedFor,
        uint256 _nonce,
        bytes memory _signature
    ) external payable returns (bool success_) {
        require(
            _signedFor == address(this),
            "KeyManager:executeRelayCall: Message not signed for this keyManager"
        );

        bytes memory blob = abi.encodePacked(
            address(this), // needs to be signed for this keyManager
            _data,
            _nonce
        );

        address from = keccak256(blob).toEthSignedMessageHash().recover(
            _signature
        );

        require(
            _verifyNonce(from, _nonce),
            "KeyManager:executeRelayCall: Incorrect nonce"
        );

        _nonceStore[from][_nonce >> 128] = _nonceStore[from][_nonce >> 128].add(1);

        _checkPermissions(from, _data);

        (success_, ) = address(account).call{value: 0, gas: gasleft()}(_data);
        if (success_) emit Executed(msg.value, _data);
    }

    function _checkPermissions(address _address, bytes calldata _data)
        internal
        view
    {
        bytes1 userPermissions = _getUserPermissions(_address);
        bytes4 erc725Selector = bytes4(_data[:4]);

        if (erc725Selector == _SETDATA_SELECTOR) {
            bytes8 setDataKey = bytes8(_data[4:12]);

            if (setDataKey == _SET_PERMISSIONS) {
                require(
                    _isAllowed(_PERMISSION_CHANGEKEYS, userPermissions),
                    "KeyManager:_checkPermissions: Not authorized to change keys"
                );
            } else {
                require(
                    _isAllowed(_PERMISSION_SETDATA, userPermissions),
                    "KeyManager:_checkPermissions: Not authorized to setData"
                );
            }
        } else if (erc725Selector == _EXECUTE_SELECTOR) {
            uint8 operationType = uint8(bytes1(_data[35:36]));
            address recipient = address(bytes20(_data[48:68]));
            uint256 value = uint256(bytes32(_data[68:100]));

            require(
                operationType < 4, // Check for CALL, DELEGATECALL or DEPLOY
                "KeyManager:_checkPermissions: Invalid operation type"
            );

            bytes1 permission;
            assembly {
                switch operationType
                case 0 { permission := _PERMISSION_CALL }
                case 1 { permission := _PERMISSION_DELEGATECALL }
                case 2 { permission := _PERMISSION_DEPLOY } // CREATE2
                case 3 { permission := _PERMISSION_DEPLOY } // CREATE
            }
            bool operationAllowed = _isAllowed(permission, userPermissions);

            if (!operationAllowed && permission == _PERMISSION_CALL) {
                revert(
                    "KeyManager:_checkPermissions: not authorized to perform CALL"
                );
            }
            if (!operationAllowed && permission == _PERMISSION_DELEGATECALL) {
                revert(
                    "KeyManager:_checkPermissions: not authorized to perform DELEGATECALL"
                );
            }
            if (!operationAllowed && permission == _PERMISSION_DEPLOY) {
                revert(
                    "KeyManager:_checkPermissions: not authorized to perform DEPLOY"
                );
            }

            require(
                _isAllowedAddress(_address, recipient),
                "KeyManager:_checkPermissions: Not authorized to interact with this address"
            );

            if (value > 0) {
                require(
                    _isAllowed(_PERMISSION_TRANSFERVALUE, userPermissions),
                    "KeyManager:_checkPermissions: Not authorized to transfer ethers"
                );
            }

            if (_data.length > 164) {
                bytes4 functionSelector = bytes4(_data[164:168]);
                if (functionSelector != 0x00000000) {
                    require(
                        _isAllowedFunction(_address, functionSelector),
                        "KeyManager:_checkPermissions: Not authorised to run this function"
                    );
                }
            }
        } else if (erc725Selector == _TRANSFEROWNERSHIP_SELECTOR) {
            require(
                _isAllowed(_PERMISSION_CHANGEOWNER, userPermissions),
                "KeyManager:_checkPermissions: Not authorized to transfer ownership"
            );
        } else {
            revert(
                "KeyManager:_checkPermissions: unknown function selector from ERC725 account"
            );
        }
    }

    function _getUserPermissions(address _address)
        internal
        view
        returns (bytes1)
    {
        bytes32 permissionKey;
        bytes memory computedKey = abi.encodePacked(_KEY_PERMISSIONS, _address);

        assembly {
            permissionKey := mload(add(computedKey, 32))
        }

        bytes1 storedPermission;
        bytes memory fetchResult = account.getDataSingle(permissionKey);

        if (fetchResult.length == 0) {
            revert(
                "KeyManager:_getUserPermissions: no permissions set for this user / caller"
            );
        }

        assembly {
            storedPermission := mload(add(fetchResult, 32))
        }

        return storedPermission;
    }

    function _getAllowedAddresses(address _sender)
        internal
        view
        returns (bytes memory)
    {
        bytes memory allowedAddressesKeyComputed = abi.encodePacked(
            _KEY_ALLOWEDADDRESSES,
            _sender
        );
        bytes32 allowedAddressesKey;
        assembly {
            allowedAddressesKey := mload(add(allowedAddressesKeyComputed, 32))
        }
        return account.getDataSingle(allowedAddressesKey);
    }

    function _getAllowedFunctions(address _sender)
        internal
        view
        returns (bytes memory)
    {
        bytes memory allowedAddressesKeyComputed = abi.encodePacked(
            _KEY_ALLOWEDFUNCTIONS,
            _sender
        );
        bytes32 allowedFunctionsKey;
        assembly {
            allowedFunctionsKey := mload(add(allowedAddressesKeyComputed, 32))
        }
        return account.getDataSingle(allowedFunctionsKey);
    }

    function _isAllowedAddress(address _sender, address _recipient)
        internal
        view
        returns (bool)
    {
        bytes memory allowedAddresses = _getAllowedAddresses(_sender);

        if (allowedAddresses.length == 0) {
            return true;
        } else {
            address[] memory allowedAddressesList = abi.decode(
                allowedAddresses,
                (address[])
            );
            if (allowedAddressesList.length == 0) {
                return true;
            } else {
                for (
                    uint256 ii = 0;
                    ii <= allowedAddressesList.length - 1;
                    ii++
                ) {
                    if (_recipient == allowedAddressesList[ii]) return true;
                }
                return false;
            }
        }
    }

    function _isAllowedFunction(address _sender, bytes4 _function)
        internal
        view
        returns (bool)
    {
        bytes memory allowedFunctions = _getAllowedFunctions(_sender);

        if (allowedFunctions.length == 0) {
            return true;
        } else {
            bytes4[] memory allowedFunctionsList = abi.decode(
                allowedFunctions,
                (bytes4[])
            );
            if (allowedFunctionsList.length == 0) {
                return true;
            } else {
                for (
                    uint256 ii = 0;
                    ii <= allowedFunctionsList.length - 1;
                    ii++
                ) {
                    if (_function == allowedFunctionsList[ii]) return true;
                }
                return false;
            }
        }
    }

    function _isAllowed(bytes1 _permission, bytes1 _addressPermission)
        internal
        pure
        returns (bool)
    {
        uint8 resultCheck = uint8(_permission) & uint8(_addressPermission);

        if (resultCheck == uint8(_permission)) {
            return true;
        } else {
            return false;
        }
    }
}