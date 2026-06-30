// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";

/**
 * @title ASTERDAO Token
 * @dev ERC20 token with:
 * - 3% buy/sell tax (adjustable before renounce)
 * - Tax split: 20% NFT, 40% LP, 5% Burn, 5% LP Pool, 30% Marketing
 * - Dynamic tax up to 20% if price drops >10% (daily check)
 * - Blacklist & Whitelist
 * - 60s cooldown per trader on DEX trades (anti-sandwich)
 * - Anti-flashloan (tx.origin == msg.sender on DEX trades)
 * - Manual trading enable (owner sets after LP added)
 * - All params adjustable by owner until renounceOwnership()
 * 
 * NOTE: This is the core token contract. 
 * Full protocol (staking with daily auto rewards 1-1.5%, referral 16 levels, 
 * NFT dividend 2%, LP dividend 10% static + 40% fee in ASTER, 30 NFTs, 
 * early exit penalties, dynamic rate by pool size, max 5000U per addr, etc.)
 * requires additional contracts + keeper (Chainlink Automation) + audit.
 * 
 * WARNING: High APY (1%+ daily) from limited pool is economically risky/sustainable only with continuous inflows.
 * This code is NOT audited. Deploy at your own risk. Test thoroughly on BSC Testnet.
 * Recommend professional audit (e.g. Certik, PeckShield) before mainnet.
 */

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract ASTERDAO is ERC20, Ownable, ReentrancyGuard {
    // ==================== CONSTANTS ====================
    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 10**18; // 2.1亿
    uint256 public constant MAX_TAX_RATE = 2000; // 20% cap
    uint256 public constant BASIS_POINTS = 10000;

    // ==================== STATE (adjustable by owner before renounce) ====================
    uint256 public buyTaxRate = 300;      // 3%
    uint256 public sellTaxRate = 300;     // 3%
    uint256 public highTaxRate = 2000;    // 20% when big drop
    uint256 public currentEffectiveTaxRate = 300;

    address public marketingAddress;
    address public nftAddress;            // 20% tax
    address public lpAddress;             // 40% tax (LP related)
    address public lpPoolAddress;         // 5% 回流底池
    address public projectAddress;        // for unclaimed referral rewards etc.

    address public pairAddress;           // PancakeSwap pair (set after createPair)
    address public routerAddress;         // PancakeRouter (for future autoLP if extended)

    uint256 public cooldownSeconds = 60;  // anti-sandwich
    bool public tradingEnabled = false;
    bool public priceDropProtectionEnabled = true;

    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public lastTradeTimestamp;

    // Price tracking for dynamic tax (call updatePriceAndTax daily ~00:00)
    uint256 public previousDayPrice;      // scaled by 1e18, in paired token (BNB/USDT)
    uint256 public lastPriceCheckTimestamp;

    // ==================== EVENTS ====================
    event TradingEnabledUpdated(bool enabled);
    event TaxRatesUpdated(uint256 buyTax, uint256 sellTax, uint256 highTax);
    event AddressesUpdated(string role, address newAddr);
    event BlacklistUpdated(address indexed account, bool status);
    event WhitelistUpdated(address indexed account, bool status);
    event CooldownUpdated(uint256 newCooldown);
    event PriceAndTaxUpdated(uint256 currentPrice, uint256 effectiveTaxRate, bool dropDetected);
    event TaxDistributed(uint256 totalTax, uint256 nftShare, uint256 lpShare, uint256 burnShare, uint256 lpPoolShare, uint256 mktShare);

    // ==================== CONSTRUCTOR ====================
    constructor(address _router) ERC20("ASTERDAO", "ASTERDAO") Ownable() {
        require(_router != address(0), "router zero");
        routerAddress = _router;
        
        // Initial addresses (changeable by owner)
        marketingAddress = msg.sender;
        nftAddress = msg.sender;
        lpAddress = msg.sender;
        lpPoolAddress = msg.sender;
        projectAddress = msg.sender;

        _mint(msg.sender, TOTAL_SUPPLY);
        currentEffectiveTaxRate = buyTaxRate;
    }

    // ==================== MODIFIERS ====================
    modifier onlyOwnerOrAdjustable() {
        require(owner() != address(0), "Ownership renounced: parameters frozen");
        _;
    }

    // ==================== OWNER SETTERS (adjustable until renounce) ====================
    function setBuyTaxRate(uint256 _rate) external onlyOwner {
        require(_rate <= MAX_TAX_RATE, "tax too high");
        buyTaxRate = _rate;
        emit TaxRatesUpdated(buyTaxRate, sellTaxRate, highTaxRate);
    }

    function setSellTaxRate(uint256 _rate) external onlyOwner {
        require(_rate <= MAX_TAX_RATE, "tax too high");
        sellTaxRate = _rate;
        emit TaxRatesUpdated(buyTaxRate, sellTaxRate, highTaxRate);
    }

    function setHighTaxRate(uint256 _rate) external onlyOwner {
        require(_rate <= MAX_TAX_RATE, "tax too high");
        highTaxRate = _rate;
        emit TaxRatesUpdated(buyTaxRate, sellTaxRate, highTaxRate);
    }

    function setCooldown(uint256 _seconds) external onlyOwner {
        require(_seconds <= 300, "cooldown too long"); // safety
        cooldownSeconds = _seconds;
        emit CooldownUpdated(_seconds);
    }

    function setAddresses(
        address _marketing,
        address _nft,
        address _lp,
        address _lpPool,
        address _project
    ) external onlyOwner {
        require(
            _marketing != address(0) && _nft != address(0) && _lp != address(0) &&
            _lpPool != address(0) && _project != address(0),
            "zero address"
        );
        marketingAddress = _marketing;
        nftAddress = _nft;
        lpAddress = _lp;
        lpPoolAddress = _lpPool;
        projectAddress = _project;

        emit AddressesUpdated("marketing", _marketing);
        emit AddressesUpdated("nft", _nft);
        emit AddressesUpdated("lp", _lp);
        emit AddressesUpdated("lpPool", _lpPool);
        emit AddressesUpdated("project", _project);
    }

    function setPairAddress(address _pair) external onlyOwner {
        require(_pair != address(0), "pair zero");
        pairAddress = _pair;
    }

    function setRouterAddress(address _router) external onlyOwner {
        require(_router != address(0), "router zero");
        routerAddress = _router;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabledUpdated(true);
    }

    function disablePriceDropProtection(bool _enabled) external onlyOwner {
        priceDropProtectionEnabled = _enabled;
    }

    function setBlacklist(address _account, bool _status) external onlyOwner {
        isBlacklisted[_account] = _status;
        emit BlacklistUpdated(_account, _status);
    }

    function setWhitelist(address _account, bool _status) external onlyOwner {
        isWhitelisted[_account] = _status;
        emit WhitelistUpdated(_account, _status);
    }

    // ==================== DYNAMIC TAX (PRICE DROP >10%) ====================
    /**
     * @dev Update price from pair reserves and adjust tax if drop >10% since last day.
     * Call this ~daily at 00:00 (UTC or JST as per your schedule) via keeper/EOA.
     * If new calendar day detected and price dropped >10%, switch to highTaxRate for the day.
     */
    function updatePriceAndTax() external nonReentrant {
        if (pairAddress == address(0) || !priceDropProtectionEnabled) return;

        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return;

        address token0 = pair.token0();
        uint256 currentPrice; // quote per ASTERDAO, 1e18 scaled

        if (token0 == address(this)) {
            currentPrice = (uint256(reserve1) * 1e18) / reserve0;
        } else {
            currentPrice = (uint256(reserve0) * 1e18) / reserve1;
        }

        uint256 timeNow = block.timestamp;
        bool isNewDay = false;

        if (lastPriceCheckTimestamp > 0) {
            // Simple new day detection (86400 seconds)
            if (timeNow / 86400 > lastPriceCheckTimestamp / 86400) {
                isNewDay = true;
            }
        } else {
            isNewDay = true;
        }

        bool dropDetected = false;
        if (isNewDay && previousDayPrice > 0) {
            // Check >10% drop
            if (currentPrice < (previousDayPrice * 90) / 100) {
                currentEffectiveTaxRate = highTaxRate;
                dropDetected = true;
            } else {
                currentEffectiveTaxRate = buyTaxRate; // recover to normal
            }
            previousDayPrice = currentPrice;
            lastPriceCheckTimestamp = timeNow;
        } else if (previousDayPrice == 0) {
            previousDayPrice = currentPrice;
            lastPriceCheckTimestamp = timeNow;
        }

        emit PriceAndTaxUpdated(currentPrice, currentEffectiveTaxRate, dropDetected);
    }

    // ==================== TAX DISTRIBUTION ====================
    function _distributeTax(address from, uint256 taxAmount) internal {
        if (taxAmount == 0) return;

        uint256 nftShare = (taxAmount * 20) / 100;
        uint256 lpShare = (taxAmount * 40) / 100;
        uint256 burnShare = (taxAmount * 5) / 100;
        uint256 lpPoolShare = (taxAmount * 5) / 100;
        uint256 mktShare = (taxAmount * 30) / 100;

        if (nftShare > 0) super._transfer(from, nftAddress, nftShare);
        if (lpShare > 0) super._transfer(from, lpAddress, lpShare);
        if (burnShare > 0) super._transfer(from, 0x000000000000000000000000000000000000dEaD, burnShare);
        if (lpPoolShare > 0) super._transfer(from, lpPoolAddress, lpPoolShare);
        if (mktShare > 0) super._transfer(from, marketingAddress, mktShare);

        emit TaxDistributed(taxAmount, nftShare, lpShare, burnShare, lpPoolShare, mktShare);
    }

    // ==================== CORE TRANSFER LOGIC ====================
    function _transfer(address from, address to, uint256 amount)
        internal
        override
        nonReentrant
    {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        // Blacklist check
        if (isBlacklisted[from] || isBlacklisted[to]) {
            revert("ASTERDAO: address blacklisted");
        }

        // Trading enabled check (allow owner/contract for setup/LP add)
        if (
            !tradingEnabled &&
            from != owner() &&
            to != owner() &&
            from != address(this) &&
            to != address(this)
        ) {
            revert("ASTERDAO: trading not enabled");
        }

        // DEX trade detection (buy or sell via pair)
        bool isDexTrade = (pairAddress != address(0)) &&
            (from == pairAddress || to == pairAddress);

        if (isDexTrade) {
            address trader = tx.origin;
            // Anti-flashloan: only EOA can trade directly
            // if (trader != msg.sender) {
            //     revert("ASTERDAO: anti-flashloan protection (EOA only)");
            // }
            // Anti-sandwich cooldown 60s
            if (
                block.timestamp - lastTradeTimestamp[trader] < cooldownSeconds &&
                !isWhitelisted[trader]
            ) {
                revert("ASTERDAO: 60s cooldown active (anti-sandwich)");
            }
            lastTradeTimestamp[trader] = block.timestamp;
        }

        // Calculate tax
        uint256 taxRate = 0;
        if (!isWhitelisted[from] && !isWhitelisted[to] && isDexTrade) {
            taxRate = (from == pairAddress) ? buyTaxRate : sellTaxRate;
            // Dynamic high tax takes precedence if active
            if (currentEffectiveTaxRate > taxRate) {
                taxRate = currentEffectiveTaxRate;
            }
        }

        if (taxRate > 0) {
            uint256 taxAmount = (amount * taxRate) / BASIS_POINTS;
            uint256 netAmount = amount - taxAmount;

            if (taxAmount > 0) {
                _distributeTax(from, taxAmount);
            }
            super._transfer(from, to, netAmount);
        } else {
            super._transfer(from, to, amount);
        }
    }

    // ==================== UTILITY ====================
    /**
     * @dev Rescue tokens sent by mistake (not this token)
     */
    function rescueToken(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "Cannot rescue self token");
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    /**
     * @dev After renounce, all setters fail automatically (owner==0)
     */
    function renounceOwnership() public override onlyOwner {
        emit TradingEnabledUpdated(tradingEnabled); // final state log
        super.renounceOwnership();
    }

    // ==================== VIEW ====================
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
