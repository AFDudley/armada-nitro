// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @dev HubCustodian's ABI for callers compiled with solc 0.8.17.
interface IHubCustodian {
    struct GroupSignature {
        uint256 commitmentX;
        uint256 commitmentY;
        uint256 z;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        GroupSignature calldata signature
    ) external payable returns (bytes memory);

    function operationHash(
        uint256 nonce,
        address target,
        uint256 value,
        bytes calldata data
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);

    function authorizeDelegate(address delegate) external;

    function revokeDelegate(address delegate) external;

    function isActiveDelegate(address delegate) external view returns (bool);

    function revocationDelay() external view returns (uint256);
}

interface IFrostTestSigner {
    function publicKey(uint256 scalar) external returns (uint256 x, uint256 y);

    function sign(
        uint256 scalar,
        bytes32 messageHash
    ) external returns (uint256 commitmentX, uint256 commitmentY, uint256 z);
}
