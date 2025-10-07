// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockERC721
 * @dev Mock ERC721 token for testing
 */
contract MockERC721 is ERC721 {
    uint256 private _currentTokenId;
    
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}
    
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _currentTokenId++;
        _mint(to, tokenId);
    }
    
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
    
    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }
}


