// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ASTERDAO NFT Cards (30 limited edition)
 * @dev ERC721 max 30 supply. Owner mints the 30 cards.
 *      Utility: Stake cards to earn share of 2% network static yields (TODO integrate with Staking contract).
 *      Use the generated image as base artwork (upload variations to IPFS/Arweave for metadata).
 *
 * Production: Use OpenZeppelin ERC721 + ERC721Enumerable if need to enumerate staked.
 * Metadata: Set baseURI to IPFS folder with json for each #1 to #30 (can be same art or unique variations).
 */

contract ASTERDAONFT /* is ERC721, Ownable from OZ */ {
    string public name = "ASTERDAO Genesis Cards";
    string public symbol = "ASTERNFT";
    uint256 public constant MAX_SUPPLY = 30;
    uint256 public currentSupply = 0;
    string public baseTokenURI;
    address public owner;

    mapping(uint256 => bool) public isStaked; // For future yield share integration
    mapping(address => uint256) public stakedBalance; // If allow multiple, but max 30 total

    event Minted(address indexed to, uint256 tokenId);
    event Staked(address indexed user, uint256 tokenId);
    event Unstaked(address indexed user, uint256 tokenId);
    event OwnershipRenounced(address indexed previousOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function mint(address to) external onlyOwner {
        require(currentSupply < MAX_SUPPLY, "All 30 NFTs already minted");
        uint256 tokenId = ++currentSupply;
        // In full OZ: _safeMint(to, tokenId);
        // For demo: emit event, actual mint logic in prod version
        emit Minted(to, tokenId);
    }

    // Batch mint for convenience (owner can mint all 30 at once or to different addresses)
    function batchMint(address[] calldata recipients) external onlyOwner {
        require(currentSupply + recipients.length <= MAX_SUPPLY, "Exceeds max 30");
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 tokenId = ++currentSupply;
            emit Minted(recipients[i], tokenId);
        }
    }

    function setBaseURI(string memory _uri) external onlyOwner {
        baseTokenURI = _uri;
    }

    // tokenURI for metadata (override in full ERC721)
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(tokenId > 0 && tokenId <= currentSupply, "Invalid tokenId");
        // Return e.g. ipfs://Qm.../metadata/{tokenId}.json or base + tokenId
        return string(abi.encodePacked(baseTokenURI, "/", uint2str(tokenId), ".json"));
    }

    // Simple uint to string helper
    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    // ============ NFT Staking for 2% yield share (stub - integrate with Staking contract) ============
    // TODO: Full integration - when user stakes NFT here, record weight, then Staking contract
    //       allocates 2% of all static yields proportionally to staked NFT holders.
    //       Since only 30, can use simple equal weight or rarity tiers.
    function stakeNFT(uint256 tokenId) external {
        // In prod: require ownerOf(tokenId) == msg.sender, transfer to this contract or mark staked
        isStaked[tokenId] = true;
        stakedBalance[msg.sender] += 1;
        emit Staked(msg.sender, tokenId);
    }

    function unstakeNFT(uint256 tokenId) external {
        require(isStaked[tokenId], "Not staked");
        isStaked[tokenId] = false;
        stakedBalance[msg.sender] -= 1;
        emit Unstaked(msg.sender, tokenId);
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipRenounced(owner);
        owner = address(0);
    }

    // In production replace with full OZ ERC721 implementation + Enumerable for easy listing
}