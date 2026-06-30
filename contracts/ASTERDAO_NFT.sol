// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC721/ERC721.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/utils/Strings.sol";

/**
 * @title ASTERDAO NFT (30 limited cards)
 * @dev Simple ERC721 for 30 NFTs. Can be used for dividend weighting (equal share or rarity).
 * In staking contract, loop 1 to 30 and send share to ownerOf(i) for the 2% static rewards.
 * Owner can mint all 30 to specific addresses (community, team, airdrop, etc.).
 */
contract ASTERDAONFT is ERC721, Ownable {
    uint256 public constant MAX_SUPPLY = 30;
    uint256 public totalMinted;

    string public baseURI;

    event NFTMinted(address indexed to, uint256 tokenId);

    constructor(string memory name_, string memory symbol_, string memory baseURI_)
        ERC721(name_, symbol_)
        Ownable()
    {
        baseURI = baseURI_;
    }

    function mint(address to) external onlyOwner {
        require(totalMinted < MAX_SUPPLY, "max 30 NFTs minted");
        uint256 tokenId = totalMinted + 1;
        _safeMint(to, tokenId);
        totalMinted++;
        emit NFTMinted(to, tokenId);
    }

    function batchMint(address[] calldata recipients) external onlyOwner {
        require(totalMinted + recipients.length <= MAX_SUPPLY, "exceeds max supply");
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 tokenId = totalMinted + 1;
            _safeMint(recipients[i], tokenId);
            totalMinted++;
            emit NFTMinted(recipients[i], tokenId);
        }
    }

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId), ".json"));
    }
}