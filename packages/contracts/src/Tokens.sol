// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

enum TokenType {
    YES,
    NO
}

abstract contract ERC20Mintable is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error CallerNotMinter(address caller);

    constructor(address minter) {
        _grantRole(MINTER_ROLE, minter);
    }

    function mint(address to, uint256 amount) public {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert CallerNotMinter(msg.sender);
        }
        _mint(to, amount);
    }
}

contract DecisionToken is ERC20, ERC20Burnable, ERC20Mintable {
    TokenType public tokenType;

    constructor(TokenType _tokenType, address minter)
        ERC20(_tokenType == TokenType.YES ? "YES" : "NO", _tokenType == TokenType.YES ? "YES" : "NO")
        ERC20Mintable(minter)
    {
        _mint(msg.sender, 0 * 10 ** decimals());
        tokenType = _tokenType;
    }
}

contract VUSD is ERC20, ERC20Burnable, ERC20Mintable {
    constructor(address minter) ERC20("Virtual USDC", "VUSD") ERC20Mintable(minter) {}
}
