// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ASTERDAO Token Contract
 * @dev ERC20 with taxes, dynamic tax on price drop, blacklist, whitelist, 60s cooldown anti-sandwich,
 *      anti-contract trading (flashloan protection), manual trading open time, adjustable params until renounce.
 *      Tax distribution: 20% NFT, 40% LP, 5% burn, 5% pool back, 30% marketing.
 *      Total supply: 210,000,000
 * 
 * WARNING: This is a conceptual implementation. NOT AUDITED. Deploying financial contracts without
 * professional audit (Certik, PeckShield, etc.) can result in loss of funds, exploits, or legal issues.
 * All values adjustable by owner before renounceOwnership(). After renounce, cannot change.
 * Integrate with PancakeSwap V2. Set pair and USDT pair after adding liquidity.
 * Use at your own extreme risk. Not financial advice.
 */

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

contract ASTERDAO {
    // For standalone demo, minimal ERC20 implemented. In production use:
    // import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
    // import "@openzeppelin/contracts/access/Ownable.sol";
    // Then: contract ASTERDAO is ERC20, Ownable {

    string public constant name = "ASTERDAO";
    string public constant symbol = "ASTERDAO";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 210_000_000 * 10**18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    address public owner;
    bool private _paused; // simple pause if needed

    // Blacklist & Whitelist
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;

    // Anti-sandwich / Cooldown
    mapping(address => uint256) public lastTradeTime;
    uint256 public cooldownTime = 60; // 60 seconds, adjustable by owner

    // Trading control - manual open
    bool public tradingEnabled = false;
    uint256 public tradingOpenTimestamp = 0;

    // Pancake pair for tax detection and price
    address public pancakePair;      // Main trading pair (e.g. ASTER/BNB or ASTER/USDT)
    address public usdtPair;         // USDT pair for accurate USD price (recommended ASTER/USDT)

    // Tax rates in basis points (100 = 1%)
    uint256 public buyTaxRate = 300;     // 3%
    uint256 public sellTaxRate = 300;    // 3%
    uint256 public highTaxRate = 2000;   // 20% when triggered
    bool public highTaxActive = false;
    uint256 public highTaxUntil = 0;
    uint256 public priceDropThreshold = 1000; // 10% in basis points

    // Tax distribution shares (sum must = 10000)
    uint256 public nftTaxShare = 2000;      // 20%
    uint256 public lpTaxShare = 4000;       // 40%
    uint256 public burnTaxShare = 500;      // 5%
    uint256 public poolBackTaxShare = 500;  // 5% back to pool/staking
    uint256 public marketingTaxShare = 3000; // 30%

    // Tax recipient wallets (set by owner, whitelist them to avoid tax on distribution)
    address public nftWallet;
    address public lpWallet;
    address public poolBackWallet;   // Recommend: address of Staking contract
    address public marketingWallet;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Price tracking for dynamic tax
    uint256 public lastPrice; // USDT per ASTER * 1e18
    uint256 public lastPriceUpdateTime;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event BlacklistUpdated(address indexed account, bool value);
    event WhitelistUpdated(address indexed account, bool value);
    event TradingStatusChanged(bool enabled, uint256 openTime);
    event TaxRatesUpdated(uint256 buy, uint256 sell, uint256 high);
    event TaxSharesUpdated(uint256 nft, uint256 lp, uint256 burn, uint256 pool, uint256 mkt);
    event WalletsUpdated(address nft, address lp, address pool, address mkt);
    event PriceAndTaxUpdated(uint256 newPrice, bool highTaxTriggered);
    event OwnershipRenounced(address indexed previousOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier tradingOpen() {
        require(tradingEnabled && block.timestamp >= tradingOpenTimestamp, "Trading not open");
        _;
    }

    constructor(
        address _marketingWallet,
        address _nftWallet,
        address _lpWallet,
        address _poolBackWallet
    ) {
        owner = msg.sender;
        _totalSupply = MAX_SUPPLY;
        _balances[msg.sender] = MAX_SUPPLY;
        emit Transfer(address(0), msg.sender, MAX_SUPPLY);

        marketingWallet = _marketingWallet;
        nftWallet = _nftWallet;
        lpWallet = _lpWallet;
        poolBackWallet = _poolBackWallet;

        // Whitelist tax wallets and owner initially
        isWhitelisted[msg.sender] = true;
        isWhitelisted[_marketingWallet] = true;
        isWhitelisted[_nftWallet] = true;
        isWhitelisted[_lpWallet] = true;
        isWhitelisted[_poolBackWallet] = true;
    }

    // ============ ERC20 Standard Functions (minimal for demo) ============
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address _owner, address spender) public view returns (uint256) {
        return _allowances[_owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _approve(from, msg.sender, currentAllowance - amount);
        _transfer(from, to, amount);
        return true;
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0), "ERC20: approve from zero");
        require(spender != address(0), "ERC20: approve to zero");
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    // ============ Core Transfer with Tax, Cooldown, Blacklist, Anti-Flash ============
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        require(_balances[from] >= amount, "ERC20: insufficient balance");
        require(!isBlacklisted[from] && !isBlacklisted[to], "Blacklisted address");

        // Skip restrictions for owner, contract itself, whitelisted
        if (from != owner && to != owner && from != address(this) && to != address(this)) {
            if (!isWhitelisted[from] && !isWhitelisted[to]) {
                // Trading must be open for pair interactions
                if (pancakePair != address(0) && (from == pancakePair || to == pancakePair)) {
                    require(tradingEnabled && block.timestamp >= tradingOpenTimestamp, "Trading closed");

                    // Anti-sandwich cooldown (60s)
                    address trader = (from == pancakePair) ? to : from;
                    require(block.timestamp >= lastTradeTime[trader] + cooldownTime, "Trade cooldown active (60s)");
                    lastTradeTime[trader] = block.timestamp;

                    // Anti-flashloan / anti-contract protection (only EOA can trade directly)
                    if (_isContract(trader) && !isWhitelisted[trader]) {
                        revert("Contract trading disabled (anti-flashloan)");
                    }
                }
            }
        }

        // Calculate tax if buy or sell
        uint256 taxRate = 0;
        bool isBuy = (from == pancakePair);
        bool isSell = (to == pancakePair);

        if ((isBuy || isSell) && !isWhitelisted[from] && !isWhitelisted[to]) {
            if (highTaxActive && block.timestamp < highTaxUntil) {
                taxRate = highTaxRate;
            } else {
                taxRate = isBuy ? buyTaxRate : sellTaxRate;
            }
        }

        if (taxRate > 0) {
            uint256 taxAmount = (amount * taxRate) / 10000;
            uint256 netAmount = amount - taxAmount;

            _balances[from] -= amount;
            _balances[to] += netAmount;

            emit Transfer(from, to, netAmount);

            // Distribute tax portions
            _distributeTax(from, taxAmount);
        } else {
            _balances[from] -= amount;
            _balances[to] += amount;
            emit Transfer(from, to, amount);
        }
    }

    function _distributeTax(address from, uint256 taxAmount) internal {
        if (taxAmount == 0) return;

        uint256 nftAmt = (taxAmount * nftTaxShare) / 10000;
        uint256 lpAmt = (taxAmount * lpTaxShare) / 10000;
        uint256 burnAmt = (taxAmount * burnTaxShare) / 10000;
        uint256 poolAmt = (taxAmount * poolBackTaxShare) / 10000;
        uint256 mktAmt = (taxAmount * marketingTaxShare) / 10000;

        // Use super/ direct balance to avoid re-entering tax logic. Whitelist tax wallets.
        if (nftAmt > 0 && nftWallet != address(0)) {
            _balances[from] -= nftAmt;
            _balances[nftWallet] += nftAmt;
            emit Transfer(from, nftWallet, nftAmt);
        }
        if (lpAmt > 0 && lpWallet != address(0)) {
            _balances[from] -= lpAmt;
            _balances[lpWallet] += lpAmt;
            emit Transfer(from, lpWallet, lpAmt);
        }
        if (burnAmt > 0) {
            _balances[from] -= burnAmt;
            _balances[DEAD] += burnAmt;
            emit Transfer(from, DEAD, burnAmt);
        }
        if (poolAmt > 0 && poolBackWallet != address(0)) {
            _balances[from] -= poolAmt;
            _balances[poolBackWallet] += poolAmt;
            emit Transfer(from, poolBackWallet, poolAmt);
        }
        if (mktAmt > 0 && marketingWallet != address(0)) {
            _balances[from] -= mktAmt;
            _balances[marketingWallet] += mktAmt;
            emit Transfer(from, marketingWallet, mktAmt);
        }
    }

    // ============ Dynamic Tax - Price Drop Detection ============
    function updatePriceAndTax() external {
        require(usdtPair != address(0), "USDT pair not set");
        require(block.timestamp >= lastPriceUpdateTime + 86400, "Can only update once per day (0:00 call recommended)");

        IPancakePair pair = IPancakePair(usdtPair);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        address token0 = pair.token0();

        uint256 currentPrice;
        if (token0 == address(this)) {
            currentPrice = (uint256(reserve1) * 1e18) / reserve0; // USDT per ASTER
        } else {
            currentPrice = (uint256(reserve0) * 1e18) / reserve1;
        }

        bool triggered = false;
        if (lastPrice > 0) {
            uint256 dropBps = lastPrice > currentPrice 
                ? ((lastPrice - currentPrice) * 10000) / lastPrice 
                : 0;
            if (dropBps > priceDropThreshold) {
                highTaxActive = true;
                highTaxUntil = block.timestamp + 86400; // Active for this day
                triggered = true;
            } else {
                highTaxActive = false;
            }
        }

        lastPrice = currentPrice;
        lastPriceUpdateTime = block.timestamp;

        emit PriceAndTaxUpdated(currentPrice, triggered);
    }

    function getCurrentPrice() public view returns (uint256) {
        if (usdtPair == address(0)) return 0;
        IPancakePair pair = IPancakePair(usdtPair);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        address token0 = pair.token0();
        if (token0 == address(this)) {
            return (uint256(reserve1) * 1e18) / reserve0;
        } else {
            return (uint256(reserve0) * 1e18) / reserve1;
        }
    }

    // ============ Owner Adjustable Settings (before renounce) ============
    function setBlacklist(address account, bool value) external onlyOwner {
        isBlacklisted[account] = value;
        emit BlacklistUpdated(account, value);
    }

    function setWhitelist(address account, bool value) external onlyOwner {
        isWhitelisted[account] = value;
        emit WhitelistUpdated(account, value);
    }

    function setCooldownTime(uint256 _seconds) external onlyOwner {
        require(_seconds <= 300, "Cooldown too long");
        cooldownTime = _seconds;
    }

    function setTradingOpenTimestamp(uint256 _timestamp) external onlyOwner {
        tradingOpenTimestamp = _timestamp;
        emit TradingStatusChanged(tradingEnabled, _timestamp);
    }

    function setTradingEnabled(bool _enabled) external onlyOwner {
        tradingEnabled = _enabled;
        emit TradingStatusChanged(_enabled, tradingOpenTimestamp);
    }

    function setPair(address _pair) external onlyOwner {
        pancakePair = _pair;
    }

    function setUSDTPair(address _pair) external onlyOwner {
        usdtPair = _pair;
    }

    function setTaxRates(uint256 _buy, uint256 _sell, uint256 _high) external onlyOwner {
        buyTaxRate = _buy;
        sellTaxRate = _sell;
        highTaxRate = _high;
        emit TaxRatesUpdated(_buy, _sell, _high);
    }

    function setTaxShares(
        uint256 _nft,
        uint256 _lp,
        uint256 _burn,
        uint256 _pool,
        uint256 _mkt
    ) external onlyOwner {
        require(_nft + _lp + _burn + _pool + _mkt == 10000, "Shares must sum to 100%");
        nftTaxShare = _nft;
        lpTaxShare = _lp;
        burnTaxShare = _burn;
        poolBackTaxShare = _pool;
        marketingTaxShare = _mkt;
        emit TaxSharesUpdated(_nft, _lp, _burn, _pool, _mkt);
    }

    function setWallets(
        address _nft,
        address _lp,
        address _poolBack,
        address _mkt
    ) external onlyOwner {
        nftWallet = _nft;
        lpWallet = _lp;
        poolBackWallet = _poolBack;
        marketingWallet = _mkt;
        // Auto whitelist new wallets
        isWhitelisted[_nft] = true;
        isWhitelisted[_lp] = true;
        isWhitelisted[_poolBack] = true;
        isWhitelisted[_mkt] = true;
        emit WalletsUpdated(_nft, _lp, _poolBack, _mkt);
    }

    function setPriceDropThreshold(uint256 _bps) external onlyOwner {
        priceDropThreshold = _bps;
    }

    // Renounce ownership - after this, no more changes possible
    function renounceOwnership() external onlyOwner {
        emit OwnershipRenounced(owner);
        owner = address(0);
    }

    // ============ Internal Helpers ============
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    // Burn function for manual burns if needed
    function burn(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        emit Transfer(msg.sender, DEAD, amount);
    }

    // Emergency withdraw if tokens stuck (only before renounce, for safety)
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(amount);
        } else {
            // For other tokens
            (bool success, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", owner, amount));
            require(success, "Transfer failed");
        }
    }
}