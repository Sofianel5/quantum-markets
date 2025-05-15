// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./interfaces/IMarketResolver.sol";

struct Outcome {
    bool proposalSuccessful;
    uint256 proposalId;
}

struct Proof {
    bytes signature;
    bytes data;
}

contract BasicMarketResolver is IMarketResolver, Ownable, AccessControl {
    bytes32 public constant ACCOUNT_HOLDER_ROLE = keccak256("ACCOUNT_HOLDER_ROLE");

    constructor(address systemAdmin, address accountHolder) Ownable(systemAdmin) {
        _grantRole(ACCOUNT_HOLDER_ROLE, accountHolder);
    }

    function verifyResolution(uint256 proposalId, bool yesOrNo, bytes memory proof)
        external
        view
        returns (bool passed)
    {
        Proof memory proofObject = abi.decode(proof, (Proof));
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(proofObject.data);
        require(SignatureChecker.isValidSignatureNow(owner(), hash, proofObject.signature), "Proof doesn't verify.");

        Outcome memory outcome = abi.decode(proofObject.data, (Outcome));
        require(outcome.proposalId == proposalId, "Not the proposal in question.");
        require(outcome.proposalSuccessful == yesOrNo, "Not the claimed outcome.");
        return true;
    }
}
