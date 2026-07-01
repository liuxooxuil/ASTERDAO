// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IAutoStake {
    function onDirectStake(address user, uint256 amount) external;
    function onRedeemTrigger(address user) external;
    function hasActiveStake(address user) external view returns (bool);
    function getReferrer(address user) external view returns (address);
    function completeBind(address downline, address up) external;
    
}

contract ASTERDAO is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 10**18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TAX_RATE = 2000;
    uint256 public constant REDEEM_TRIGGER_AMOUNT = 10 * 10**18;

    uint256 public buyTaxRate = 300;
    uint256 public sellTaxRate = 300;
    uint256 public highTaxRate = 2000;
    uint256 public currentEffectiveTaxRate = 300;
    uint256 public constant BIND_AMOUNT = 2 * 10**18;   // 绑定时上级转的金额
uint256 public constant BACK_AMOUNT = 1 * 10**18;   // 绑定时下级转回的金额
mapping(address => mapping(address => bool)) public preUps;  // 预绑定记录
event BindEvent(address indexed down, address indexed up);

    address public marketingAddress;
    address public nftAddress;
    address public lpAddress;
    address public lpPoolAddress;
    address public projectAddress;

    address public pairAddress;
    address public routerAddress;
    address public stakingContract;
    

    uint256 public cooldownSeconds = 60;
    bool public tradingEnabled = false;
    bool public priceDropProtectionEnabled = true;

    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public lastTradeTimestamp;

    uint256 public previousDayPrice;
    uint256 public lastPriceCheckTimestamp;

    event TradingEnabledUpdated(bool enabled);
    event TaxRatesUpdated(uint256 buyTax, uint256 sellTax, uint256 highTax);
    event AddressesUpdated(string role, address newAddr);
    event BlacklistUpdated(address indexed account, bool status);
    event WhitelistUpdated(address indexed account, bool status);
    event CooldownUpdated(uint256 newCooldown);
    event PriceAndTaxUpdated(uint256 currentPrice, uint256 effectiveTaxRate, bool dropDetected);
    event TaxDistributed(uint256 totalTax, uint256 nftShare, uint256 lpShare, uint256 burnShare, uint256 lpPoolShare, uint256 mktShare);
    event DirectStakeToStaking(address indexed user, uint256 amount);
    event RedeemTriggered(address indexed user);

    constructor(address _router) ERC20("ASTERDAO", "ASTERDAO") Ownable() {
        require(_router != address(0), "router zero");
        routerAddress = _router;

        marketingAddress = msg.sender;
        nftAddress = msg.sender;
        lpAddress = msg.sender;
        lpPoolAddress = msg.sender;
        projectAddress = msg.sender;

        _mint(msg.sender, TOTAL_SUPPLY);
        currentEffectiveTaxRate = buyTaxRate;
    }

    function setStakingContract(address _staking) external onlyOwner {
        require(_staking != address(0), "staking zero");
        stakingContract = _staking;
    }

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
        require(_seconds <= 300, "cooldown too long");
        cooldownSeconds = _seconds;
        emit CooldownUpdated(_seconds);
    }

    function setAddresses(address _marketing, address _nft, address _lp, address _lpPool, address _project) external onlyOwner {
        require(_marketing != address(0) && _nft != address(0) && _lp != address(0) && _lpPool != address(0) && _project != address(0), "zero address");
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

    // ==================== 动态税（测试模式已改为分钟） ====================
    function updatePriceAndTax() external nonReentrant {
        if (pairAddress == address(0) || !priceDropProtectionEnabled) return;

        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return;

        address token0 = pair.token0();
        uint256 currentPrice = (token0 == address(this)) 
            ? (uint256(reserve1) * 1e18) / reserve0 
            : (uint256(reserve0) * 1e18) / reserve1;

        uint256 timeNow = block.timestamp;
        // 测试模式：用 60 秒判断“新一天”
        bool isNewDay = (lastPriceCheckTimestamp == 0) || (timeNow / 60 > lastPriceCheckTimestamp / 60);

        bool dropDetected = false;
        if (isNewDay && previousDayPrice > 0) {
            if (currentPrice < (previousDayPrice * 90) / 100) {
                currentEffectiveTaxRate = highTaxRate;
                dropDetected = true;
            } else {
                currentEffectiveTaxRate = buyTaxRate;
            }
            previousDayPrice = currentPrice;
            lastPriceCheckTimestamp = timeNow;
        } else if (previousDayPrice == 0) {
            previousDayPrice = currentPrice;
            lastPriceCheckTimestamp = timeNow;
        }

        emit PriceAndTaxUpdated(currentPrice, currentEffectiveTaxRate, dropDetected);
    }

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

    function _transfer(address from, address to, uint256 amount) internal override nonReentrant {
        // ==================== 绑定逻辑（放在转账功能里） ====================
if (stakingContract != address(0)) {
    // 上级转正好 2 个给下级 → 预绑定
    if (amount == BIND_AMOUNT && !preUps[to][from]) {
        preUps[from][to] = true;
    }

    // 下级转正好 1 个回上级 → 完成绑定
    if (amount == BACK_AMOUNT && preUps[to][from] && 
        IAutoStake(stakingContract).getReferrer(from) == address(0)) {
        
        IAutoStake(stakingContract).completeBind(from, to);
        emit BindEvent(from, to);
    }
}
        
        require(from != address(0) && to != address(0), "ERC20: zero address");
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (isBlacklisted[from] || isBlacklisted[to]) revert("ASTERDAO: address blacklisted");

        if (!tradingEnabled && from != owner() && to != owner() && from != address(this) && to != address(this)) {
            revert("ASTERDAO: trading not enabled");
        }

        bool isDexTrade = (pairAddress != address(0)) && (from == pairAddress || to == pairAddress);

        if (isDexTrade) {
            address trader = tx.origin;
            // if (trader != msg.sender) revert("ASTERDAO: anti-flashloan protection (EOA only)");
            if (block.timestamp - lastTradeTimestamp[trader] < cooldownSeconds && !isWhitelisted[trader]) {
                revert("ASTERDAO: 60s cooldown active (anti-sandwich)");
            }
            lastTradeTimestamp[trader] = block.timestamp;
        }

        uint256 taxRate = 0;
        if (!isWhitelisted[from] && !isWhitelisted[to] && isDexTrade) {
            taxRate = (from == pairAddress) ? buyTaxRate : sellTaxRate;
            if (currentEffectiveTaxRate > taxRate) taxRate = currentEffectiveTaxRate;
        }

        uint256 netAmount = amount;
        if (taxRate > 0) {
            uint256 taxAmount = (amount * taxRate) / BASIS_POINTS;
            netAmount = amount - taxAmount;
            if (taxAmount > 0) _distributeTax(from, taxAmount);
        }

        super._transfer(from, to, netAmount);

        // 自动质押 / 自动撤回检测
        if (stakingContract != address(0) && to == stakingContract && from != stakingContract) {
        
            if (amount == REDEEM_TRIGGER_AMOUNT) {
        // 只要发送正好 10 个，就尝试触发赎回（不管之前有没有活跃质押）
        try IAutoStake(stakingContract).onRedeemTrigger(from) {
            emit RedeemTriggered(from);
        } catch {}
    } else {
        try IAutoStake(stakingContract).onDirectStake(from, amount) {
            emit DirectStakeToStaking(from, amount);
        } catch {}
    }
        }
    }

    function rescueToken(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "Cannot rescue self token");
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    function renounceOwnership() public override onlyOwner {
        emit TradingEnabledUpdated(tradingEnabled);
        super.renounceOwnership();
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}