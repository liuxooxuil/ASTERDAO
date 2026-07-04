// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC721/ERC721.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/utils/Strings.sol";

contract ASTERDAONFT is ERC721, Ownable {
    uint256 public constant MAX_SUPPLY = 30;
    uint256 public totalMinted;
    string public baseURI;
    address public tokenContract;

    mapping(uint256 => address) public nftOwners;

    event NFTMinted(address indexed to, uint256 tokenId);
    event NFTDividendDistributed(uint256 perNFT);

    constructor(address _tokenContract) ERC721("ASTERDAO NFT", "ADNFT") Ownable() {
        tokenContract = _tokenContract;
    }

    modifier onlyTokenOrOwner() {
        require(msg.sender == tokenContract || msg.sender == owner(), "Only token contract or owner");
        _;
    }

    function mint(address to) external onlyTokenOrOwner {
        require(totalMinted < MAX_SUPPLY, "Max supply reached");
        uint256 tokenId = ++totalMinted;
        _safeMint(to, tokenId);
        nftOwners[tokenId] = to;
        emit NFTMinted(to, tokenId);
    }
    

    function batchMint(address[] calldata recipients) external onlyTokenOrOwner {
        require(totalMinted + recipients.length <= MAX_SUPPLY, "Exceeds max supply");
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 tokenId = ++totalMinted;
            _safeMint(recipients[i], tokenId);
            nftOwners[tokenId] = recipients[i];
            emit NFTMinted(recipients[i], tokenId);
        }
    }
    //0x60986D92F7aAFF3E4Bfb5F9B2048b2b8b22Ab4e1
    function distributeDividends(uint256 perNFT) external {
        require(msg.sender == tokenContract, "Only token contract");
        emit NFTDividendDistributed(perNFT);
    }

    function setBaseURI(string calldata _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Nonexistent token");
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId), ".json"));
    }

    function nftBalanceOf(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }
}