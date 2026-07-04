// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/ERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/utils/Strings.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
}
interface IAutoStake {
    function onDirectStake(address user, uint256 amount) external;
    function onRedeemTrigger(address user) external;
    function hasActiveStake(address user) external view returns (bool);
    function getReferrer(address user) external view returns (address);
    function completeBind(address downline, address up) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

contract ASTERDAO is ERC20, Ownable, ReentrancyGuard {

    // ==================== Token 基础 ====================
    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 10**18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TAX_RATE = 2000;
    uint256 public constant BIND_AMOUNT = 2 * 10**18;
    uint256 public constant BACK_AMOUNT = 1 * 10**18;

    uint256 public buyTaxRate = 300;
    uint256 public sellTaxRate = 300;
    uint256 public highTaxRate = 2000;
    uint256 public currentEffectiveTaxRate = 300;

    address public marketingAddress;
    address public nftAddress;
    address public lpAddress;
    address public lpPoolAddress;
    address public projectAddress;
    address public projectTreasury;

    address public pairAddress;
    address public bnbUsdtPairAddress;
    address public routerAddress;
    address public stakingContract;

    uint256 public cooldownSeconds = 60;
    bool public tradingEnabled = false;
    bool public priceDropProtectionEnabled = true;

    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public lastTradeTimestamp;
    mapping(address => mapping(address => bool)) public preUps;
    mapping(address => LPStakeInfo) public lpStakes;
    mapping(address => bool) public isSpecialLPUser;

    uint256 public previousDayPrice;
    uint256 public lastPriceCheckTimestamp;

    // ==================== Staking ====================
    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_UNITS = 10;
    uint256 public constant TIME_UNIT = 60;

    uint256 public rateHigh = 150;
    uint256 public rateMid = 120;
    uint256 public rateLow = 100;

    uint256[16] public referralRates = [
        1000, 600, 133, 133, 134, 18, 18, 18, 18, 18,
        18, 18, 18, 18, 18, 20
    ];

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 autoRewardUntil;
        address referrer;
        bool active;
    }

    struct LPPosition {
        uint256 amount;
        uint256 depositTime;
        bool claimed;
    }

    struct LPStakeInfo {
        uint256 amount;
        uint256 stakeTime;
        uint256 lastClaimTime;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => address) public referrers;
    mapping(address => bool) public isEffectiveUser;
    mapping(address => LPPosition) public lpPositions;
    mapping(address => bool) public isLPWhitelisted;

    uint256 public totalStaked;
    uint256 public minEffectiveUSD = 50 * 1e18;
    uint256 public maxStakePerUser = 5000 * 10**18;

    IERC20 public lpToken;

    // ==================== 分红池 ====================
    uint256 public lpDividendPool;
    uint256 public nftRewardPool;
    uint256 public lpDividendThreshold = 5000 * 10**18;
    uint256 public nftDividendThreshold = 300 * 10**18;

    address public constant REAL_ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    uint256 public minLPTaxSwapAmount = 500 * 10**18;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 public maxStakePerUserUSD = 5000 * 1e18;   // 默认 5000 USD

    address[] public lpProviderList;

    // ==================== NFT ====================
    uint256 public constant MAX_NFT_SUPPLY = 30;
    uint256 public nftTotalMinted;
    mapping(uint256 => address) public nftOwners;
    mapping(address => uint256) public nftBalances;
    string public baseURI;

    // ==================== 事件 ====================
    event TaxDistributed(uint256 totalTax, uint256 nftShare, uint256 lpShare, uint256 burnShare, uint256 lpPoolShare, uint256 mktShare);
    event BindEvent(address indexed down, address indexed up);
    event Staked(address indexed user, uint256 amount, bool isEffective, bool isAuto);
    event RewardClaimed(address indexed user, uint256 userNet, uint256 referralDistributed, uint256 periodsClaimed, bool wasEffective);
    event Redeemed(address indexed user, uint256 returnedAmount, uint256 burnedAmount, uint256 penaltyRate);
    event LPDividendDistributed(address indexed user, uint256 amount);
    event NFTDividendDistributed(uint256 totalAmount, uint256 perNFT);
    event BuybackToRealASTER(uint256 projectTokenUsed, uint256 realASTERBought);
    event BoundReferrer(address indexed user, address indexed referrer);
    event TaxRatesUpdated(uint256 buyTax, uint256 sellTax, uint256 highTax);
    event AddressesUpdated(string role, address newAddr);
    event TradingEnabledUpdated(bool enabled);
    event CooldownUpdated(uint256 newCooldown);
    event PriceAndTaxUpdated(uint256 currentPrice, uint256 effectiveTaxRate, bool dropDetected);
    event BlacklistUpdated(address indexed account, bool status);
    event WhitelistUpdated(address indexed account, bool status);
    event EffectiveUserUpdated(address indexed user, bool status);
    event AutoRewardActivated(address indexed user, uint256 periods, uint256 newUntil);
    event LPStaked(address indexed user, uint256 amount);
    event LPUnstaked(address indexed user, uint256 amount, bool earlyWithdraw);
    event LPDeposited(address indexed user, uint256 amount);
    event LPWithdrawn(address indexed user, uint256 usdtAmount, uint256 rewardAmount);
    event NFTMinted(address indexed to, uint256 tokenId);
    event ReferralBonusPaid(address indexed referrer, address indexed downline, uint256 amount, uint8 level);

    constructor(address _router, address _projectTreasury)
        ERC20("ASTERDAO", "ASTER")
        Ownable()
    {
        require(_router != address(0) && _projectTreasury != address(0), "zero address");
        routerAddress = _router;
        projectTreasury = _projectTreasury;

        marketingAddress = msg.sender;
        nftAddress = msg.sender;
        lpAddress = msg.sender;
        lpPoolAddress = msg.sender;
        projectAddress = msg.sender;
        stakingContract = address(this);

        _mint(msg.sender, TOTAL_SUPPLY);
        currentEffectiveTaxRate = buyTaxRate;
    }

    // ==================== LP Token ====================
    function setLPToken(address _lpToken) external onlyOwner {
        require(_lpToken != address(0), "zero address");
        lpToken = IERC20(_lpToken);
    }

    // ==================== 价格查询 ====================
    function setPairAddress(address _pair) external onlyOwner {
        require(_pair != address(0), "pair zero");
        pairAddress = _pair;
    }

    function setBnbUsdtPairAddress(address _pair) external onlyOwner {
        require(_pair != address(0), "pair zero");
        bnbUsdtPairAddress = _pair;
    }

    // ==================== LP 功能 ====================
    function stakeLP(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        lpToken.transferFrom(msg.sender, address(this), amount);

        LPStakeInfo storage stake = lpStakes[msg.sender];
        if (stake.amount == 0) {
            stake.stakeTime = block.timestamp;
        }
        stake.amount += amount;

        emit LPStaked(msg.sender, amount);
    }

    function unstakeLP() external {
        LPStakeInfo storage stake = lpStakes[msg.sender];
        require(stake.amount > 0, "No LP staked");

        uint256 daysStaked = (block.timestamp - stake.stakeTime) / 1 days;
        uint256 amount = stake.amount;

        if (isSpecialLPUser[msg.sender] && daysStaked < 100) {
            _handleEarlyUnstake(msg.sender, amount);
            emit LPUnstaked(msg.sender, amount, true);
        } else {
            lpToken.transfer(msg.sender, amount);
            emit LPUnstaked(msg.sender, amount, false);
        }

        delete lpStakes[msg.sender];
    }

    // function _handleEarlyUnstake(address user, uint256 lpAmount) internal {
    //     IUniswapV2Router02 router = IUniswapV2Router02(PANCAKE_ROUTER);
    //     lpToken.approve(PANCAKE_ROUTER, lpAmount);

    //     (uint amountToken, uint amountUSDT) = router.removeLiquidity(
    //         address(this),
    //         USDT,
    //         lpAmount,
    //         0,
    //         0,
    //         address(this),
    //         block.timestamp + 300
    //     );

    //     if (amountToken > 0) {
    //         super._transfer(address(this), 0x000000000000000000000000000000000000dEaD, amountToken);
    //     }

    //     if (amountUSDT > 0) {
    //         IERC20(USDT).transfer(user, amountUSDT);
    //     }
    // }

    function _handleEarlyUnstake(address user, uint256 lpAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(PANCAKE_ROUTER);
        lpToken.approve(PANCAKE_ROUTER, lpAmount);

        // 移除 ASTERDAO / BNB 流动性
        (uint amountToken, uint amountBNB) = router.removeLiquidity(
            address(this),
            WBNB,
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp + 300
        );

        // 销毁 ASTERDAO 部分
        if (amountToken > 0) {
            super._transfer(address(this), 0x000000000000000000000000000000000000dEaD, amountToken);
        }

        // 把 BNB 换成 USDT 再退给用户
        if (amountBNB > 0) {
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = USDT;

            router.swapExactETHForTokens{value: amountBNB}(
                0,
                path,
                user,
                block.timestamp + 300
            );
        }
    }

    function getUserLPValueInUSDT(address user) public view returns (uint256) {
        LPStakeInfo storage stake = lpStakes[user];
        if (stake.amount == 0) return 0;

        IUniswapV2Pair pair = IUniswapV2Pair(address(lpToken));
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        address token0 = pair.token0();
        uint256 reserveUSDT = (token0 == USDT) ? reserve0 : reserve1;

        uint256 userShare = (stake.amount * 1e18) / totalSupply;
        return (userShare * reserveUSDT) / 1e18;
    }

    function distributeLPDividends(address[] calldata users) external onlyOwner {
        uint256 totalDividend = lpDividendPool;
        require(totalDividend > 0, "No dividend to distribute");

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < users.length; i++) {
            totalWeight += getUserLPValueInUSDT(users[i]);
        }
        require(totalWeight > 0, "No LP weight");

        for (uint256 i = 0; i < users.length; i++) {
            uint256 weight = getUserLPValueInUSDT(users[i]);
            if (weight == 0) continue;

            uint256 share = (totalDividend * weight) / totalWeight;
            if (share > 0 && IERC20(REAL_ASTER).balanceOf(address(this)) >= share) {
                IERC20(REAL_ASTER).transfer(users[i], share);
                emit LPDividendDistributed(users[i], share);
            }
        }

        lpDividendPool = 0;
    }

    // ==================== 价格查询 ====================
    function getCurrentPrice() public view returns (uint256) {
        if (pairAddress == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        address token0 = pair.token0();
        return token0 == address(this)
            ? (uint256(reserve1) * 1e18) / reserve0
            : (uint256(reserve0) * 1e18) / reserve1;
    }

    function getBnbPriceInUSD() public view returns (uint256) {
        if (bnbUsdtPairAddress == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(bnbUsdtPairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        address token0 = pair.token0();
        address wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        return token0 == wbnb
            ? (uint256(reserve1) * 1e18) / reserve0
            : (uint256(reserve0) * 1e18) / reserve1;
    }

    function getUSDValue(uint256 amount) public view returns (uint256) {
        uint256 p1 = getCurrentPrice();
        uint256 p2 = getBnbPriceInUSD();
        if (p1 == 0 || p2 == 0) return 0;
        return (amount * p1 * p2) / 1e36;
    }

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

    // ==================== 管理员设置 ====================
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

    // ==================== 核心 _transfer ====================
    function _transfer(address from, address to, uint256 amount) internal override {

        // ====================== 发送1个代币领取收益 ======================
        if (amount == 1 * 10**18 && stakes[user].active) {
            
            uint256 reward = pendingReward(user);
            
            if (reward > 0) {
                // 更新最后领取时间，防止重复计算
                stakes[user].lastClaimTime = block.timestamp;
                
                // 把收益真正转给用户
                super._transfer(address(this), user, reward);
                
                emit RewardClaimed(user, reward, 0, 0, isEffectiveUser[user]);
            }
    
            
            return;
        }

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
            if (block.timestamp - lastTradeTimestamp[trader] < cooldownSeconds && !isWhitelisted[trader]) {
                revert("ASTERDAO: 60s cooldown active");
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

        if (to == address(this) && from != address(this)) {
            _autoStake(from, amount);
        }
    }

    function _distributeTax(address from, uint256 taxAmount) internal {
        if (taxAmount == 0) return;

        uint256 nftShare = (taxAmount * 20) / 100;
        uint256 lpShare = (taxAmount * 40) / 100;
        uint256 burnShare = (taxAmount * 5) / 100;
        uint256 lpPoolShare = (taxAmount * 5) / 100;
        uint256 mktShare = (taxAmount * 30) / 100;

        if (nftShare > 0) super._transfer(from, nftAddress, nftShare);
        if (burnShare > 0) super._transfer(from, 0x000000000000000000000000000000000000dEaD, burnShare);
        if (lpPoolShare > 0) super._transfer(from, lpPoolAddress, lpPoolShare);
        if (mktShare > 0) super._transfer(from, marketingAddress, mktShare);

        // if (lpShare > 0) {
        //     super._transfer(from, address(this), lpShare);
        //     if (lpShare >= minLPTaxSwapAmount) {
        //         _autoSwapToRealASTER(lpShare);
        //     }
        // }
        if (lpShare > 0) {
            super._transfer(from, address(this), lpShare);
            _autoSwapToRealASTER(lpShare);   // 只要有 LP 税就尝试换
        }

        emit TaxDistributed(taxAmount, nftShare, lpShare, burnShare, lpPoolShare, mktShare);
    }

    // function _autoSwapToRealASTER(uint256 amountIn) internal {
    //     _approve(address(this), PANCAKE_ROUTER, amountIn);

    //     address[] memory path1 = new address[](2);
    //     path1[0] = address(this);
    //     path1[1] = USDT;

    //     try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(
    //         amountIn, 0, path1, address(this), block.timestamp + 300
    //     ) returns (uint[] memory amounts) {
    //         uint256 usdtAmount = amounts[1];

    //         address[] memory path2 = new address[](2);
    //         path2[0] = USDT;
    //         path2[1] = REAL_ASTER;

    //         try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(
    //             usdtAmount, 0, path2, address(this), block.timestamp + 300
    //         ) returns (uint[] memory amounts2) {
    //             lpDividendPool += amounts2[1];
    //         } catch {}
    //     } catch {}
    // }

    function _autoSwapToRealASTER(uint256 amountIn) internal {
        if (amountIn == 0) return;

        _approve(address(this), PANCAKE_ROUTER, amountIn);

        // ASTERDAO  WBNB
        address[] memory path1 = new address[](2);
        path1[0] = address(this);
        path1[1] = WBNB;

        try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(
            amountIn,
            0,
            path1,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory amounts) {
            uint256 wbnbAmount = amounts[1];

            // WBNB →  ASTER
            address[] memory path2 = new address[](2);
            path2[0] = WBNB;
            path2[1] = REAL_ASTER;

            try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(
                wbnbAmount,
                0,
                path2,
                address(this),
                block.timestamp + 300
            ) returns (uint[] memory amounts2) {
                lpDividendPool += amounts2[1];
            } catch {}
        } catch {}
    }

    // ==================== 自动质押 + 发送1个代币领取收益（修复版） ====================
    function _autoStake(address user, uint256 amount) internal {
        if (amount == 0) return;

        // ====================== 发送1个代币领取收益 ======================
        if (amount == 1 * 10**18 && stakes[user].active) {
            
            uint256 reward = pendingReward(user);
            
            if (reward > 0) {
                stakes[user].lastClaimTime = block.timestamp;
                super._transfer(address(this), user, reward);
                
                emit RewardClaimed(user, reward, 0, 0, isEffectiveUser[user]);
            }
            
            // 同时激活10期自动收益窗口
            stakes[user].autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
            emit AutoRewardActivated(user, 10, stakes[user].autoRewardUntil);
            
            return;
        }
        // ====================== 发送1个代币领取收益结束 ======================

        // 原有重复质押检查
        if (stakes[user].active) {
            revert("already staking, please redeem first");
        }

        _checkMaxStake(user, amount);

        uint256 usdValue = getUSDValue(amount);
        bool makesEffective = usdValue >= minEffectiveUSD;

        if (makesEffective) {
            isEffectiveUser[user] = true;
            emit EffectiveUserUpdated(user, true);
        }

        stakes[user] = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
            autoRewardUntil: 0,
            referrer: referrers[user],
            active: true
        });

        totalStaked += amount;
        emit Staked(user, amount, makesEffective, true);
    }

    // // ==================== 自动质押 ====================
    // function _autoStake(address user, uint256 amount) internal {
    //     if (amount == 0) return;

    //     if (amount == 1 * 10**18 && stakes[user].active) {
    //         stakes[user].autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
    //         emit AutoRewardActivated(user, 10, stakes[user].autoRewardUntil);
    //         return;
    //     }

    //     if (stakes[user].active) {
    //         revert("already staking, please redeem first");
    //     }

    //     _checkMaxStake(user, amount);

    //     uint256 usdValue = getUSDValue(amount);
    //     bool makesEffective = usdValue >= minEffectiveUSD;

    //     if (makesEffective) {
    //         isEffectiveUser[user] = true;
    //         emit EffectiveUserUpdated(user, true);
    //     }

    //     stakes[user] = StakeInfo({
    //         amount: amount,
    //         startTime: block.timestamp,
    //         lastClaimTime: block.timestamp,
    //         autoRewardUntil: 0,
    //         referrer: referrers[user],
    //         active: true
    //     });

    //     totalStaked += amount;
    //     emit Staked(user, amount, makesEffective, true);
    // }

    // ==================== 查询上级推荐链 ====================
    function getUplineChain(address user, uint8 maxDepth) public view returns (address[] memory) {
        address[] memory chain = new address[](maxDepth);
        address current = referrers[user];
        uint8 i = 0;
        while (current != address(0) && i < maxDepth) {
            chain[i] = current;
            current = referrers[current];
            i++;
        }
        return chain;
    }

    // ==================== Staking 功能 ====================
    function getCurrentRate() public view returns (uint256) {
        if (totalStaked >= 100_000_000 * 10**18) return rateHigh;
        if (totalStaked >= 50_000_000 * 10**18) return rateMid;
        if (totalStaked >= 20_000_000 * 10**18) return rateLow;
        return 0;
    }

    function hasActiveStake(address user) external view returns (bool) {
        return stakes[user].active;
    }

    function getReferrer(address user) public view returns (address) {
        return referrers[user];
    }

    function stake(uint256 amount, address referrer) external payable nonReentrant {
        require(amount > 0, "amount > 0");
        require(msg.value > 0, "send some BNB");
        require(!stakes[msg.sender].active, "already staking, redeem first");

        require(transferFrom(msg.sender, address(this), amount), "transferFrom failed");

        _checkMaxStake(msg.sender, amount);

        uint256 usdValue = getUSDValue(amount);
        bool makesEffective = usdValue >= minEffectiveUSD;

        if (makesEffective) {
            isEffectiveUser[msg.sender] = true;
            emit EffectiveUserUpdated(msg.sender, true);
        }

        if (referrers[msg.sender] == address(0) && referrer != address(0) && referrer != msg.sender) {
            referrers[msg.sender] = referrer;
            emit BoundReferrer(msg.sender, referrer);
        }

        stakes[msg.sender] = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
            autoRewardUntil: 0,
            referrer: referrers[msg.sender],
            active: true
        });

        totalStaked += amount;
        emit Staked(msg.sender, amount, makesEffective, false);
    }

    function claimDailyReward() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");

        uint256 rate = getCurrentRate();
        if (rate == 0) {
            userStake.lastClaimTime = block.timestamp;
            return;
        }

        uint256 periodsPassed = (block.timestamp - userStake.lastClaimTime) / TIME_UNIT;
        if (periodsPassed == 0) return;
        periodsPassed = periodsPassed > STAKE_PERIOD_UNITS ? STAKE_PERIOD_UNITS : periodsPassed;

        uint256 grossReward = (userStake.amount * rate * periodsPassed) / 10000;

        uint256 lpShare = (grossReward * 10) / 100;
        uint256 nftShare = (grossReward * 2) / 100;

        lpDividendPool += lpShare;
        nftRewardPool += nftShare;

        uint256 remaining = grossReward - lpShare - nftShare;

        uint256 referralTotal = (grossReward * 10) / 100;
        uint256 userNet = remaining - referralTotal;
        if (userNet < 0) userNet = 0;

        uint256 actuallyDistributed = 0;
        if (userStake.referrer != address(0) && isEffectiveUser[msg.sender]) {
            actuallyDistributed = _distributeReferralRewards(msg.sender, referralTotal, userStake.referrer);
        } else if (referralTotal > 0 && projectTreasury != address(0)) {
            super._transfer(address(this), projectTreasury, referralTotal);
            actuallyDistributed = referralTotal;
        }

        if (userNet > 0) {
            super._transfer(address(this), msg.sender, userNet);
        }

        userStake.lastClaimTime = block.timestamp;
        emit RewardClaimed(msg.sender, userNet, actuallyDistributed, periodsPassed, isEffectiveUser[msg.sender]);
    }

    function _calculateReferralTotal(uint256 grossReward, address startReferrer) internal view returns (uint256) {
        uint256 total = 0;
        address current = startReferrer;

        for (uint8 level = 0; level < MAX_REFERRAL_LEVELS && current != address(0); level++) {
            uint256 share = (grossReward * referralRates[level]) / 10000;
            total += share;
            current = referrers[current];
        }
        return total;
    }

    function _distributeReferralRewards(address downline, uint256 totalReferralAmount, address startReferrer) internal returns (uint256 distributed) {
        address current = startReferrer;
        uint256 remaining = totalReferralAmount;

        for (uint8 level = 0; level < MAX_REFERRAL_LEVELS && current != address(0); level++) {
            uint256 share = (totalReferralAmount * referralRates[level]) / 10000;
            if (share > 0 && remaining >= share) {
                super._transfer(address(this), current, share);
                emit ReferralBonusPaid(current, downline, share, level + 1);
                distributed += share;
                remaining -= share;
            }
            current = referrers[current];
        }

        if (remaining > 0 && projectTreasury != address(0)) {
            super._transfer(address(this), projectTreasury, remaining);
            distributed += remaining;
        }
        return distributed;
    }

    function redeem() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");
        require(userStake.amount > 0, "no stake amount");

        uint256 principal = userStake.amount;
        if (totalStaked >= principal) {
            totalStaked -= principal;
        } else {
            totalStaked = 0;
        }

        uint256 periodsStaked = (block.timestamp - userStake.startTime) / TIME_UNIT;
        uint256 returnRate = periodsStaked <= 10 ? 70 : (periodsStaked <= 20 ? 80 : (periodsStaked <= 30 ? 90 : 100));

        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        userStake.active = false;
        userStake.amount = 0;
        userStake.autoRewardUntil = 0;

        if (returnAmount > 0) {
            super._transfer(address(this), msg.sender, returnAmount);
        }
        if (burnAmount > 0) {
            super._transfer(address(this), 0x000000000000000000000000000000000000dEaD, burnAmount);
        }

        emit Redeemed(msg.sender, returnAmount, burnAmount, returnRate);
    }

    // function _checkMaxStake(address user, uint256 newAmount) internal view {
    //     require(stakes[user].amount + newAmount <= maxStakePerUser, "exceeds max stake per user");
    // }

    function setMaxStakePerUserUSD(uint256 _usdAmount) external onlyOwner {
        maxStakePerUserUSD = _usdAmount;
    }
    function _checkMaxStake(address user, uint256 newAmount) internal view {
        uint256 currentStakeUSD = getUSDValue(stakes[user].amount);
        uint256 newStakeUSD = getUSDValue(newAmount);
        
        require(currentStakeUSD + newStakeUSD <= maxStakePerUserUSD, 
                "Exceeds max stake per user (USD limit)");
    }

    // ==================== LP 功能 ====================
    function addLPWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            if (!isLPWhitelisted[users[i]]) {
                isLPWhitelisted[users[i]] = true;
                lpProviderList.push(users[i]);
            }
        }
    }

    function depositLP(uint256 amount) external nonReentrant {
        require(isLPWhitelisted[msg.sender], "Not whitelisted");
        require(amount > 0, "Amount must be greater than 0");
        require(address(lpToken) != address(0), "LP token not set");

        require(lpToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        lpPositions[msg.sender] = LPPosition({
            amount: amount,
            depositTime: block.timestamp,
            claimed: false
        });

        emit LPDeposited(msg.sender, amount);
    }

    // ==================== 回购真实 ASTER ====================
    function buybackToRealASTER(uint256 amountIn) external onlyOwner {
        require(amountIn > 0 && balanceOf(address(this)) >= amountIn, "insufficient balance");

        _approve(address(this), PANCAKE_ROUTER, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = REAL_ASTER;

        uint[] memory amounts = IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 bought = amounts[1];
        lpDividendPool += bought;

        emit BuybackToRealASTER(amountIn, bought);
    }

    // ==================== LP 批量加权分红 ====================
    function distributeLPDividendBatch(address[] calldata users) external onlyOwner {
        require(lpDividendPool > 0, "no dividend pool");

        uint256 totalLP;
        for (uint256 i = 0; i < users.length; i++) {
            totalLP += lpPositions[users[i]].amount;
        }
        require(totalLP > 0, "no LP in this batch");

        uint256 poolBefore = lpDividendPool;
        uint256 distributed;

        for (uint256 i = 0; i < users.length; i++) {
            if (lpPositions[users[i]].amount == 0) continue;
            uint256 share = (poolBefore * lpPositions[users[i]].amount) / totalLP;
            if (share > 0 && IERC20(REAL_ASTER).balanceOf(address(this)) >= share) {
                IERC20(REAL_ASTER).transfer(users[i], share);
                distributed += share;
                emit LPDividendDistributed(users[i], share);
            }
        }

        lpDividendPool -= distributed;
    }

    // ==================== NFT 分红 ====================
    function distributeNFTDividends() external {
        require(nftRewardPool >= nftDividendThreshold, "below threshold");
        uint256 perNFT = nftRewardPool / 30;
        nftRewardPool = 0;

        for (uint256 i = 1; i <= 30; i++) {
            address holder = nftOwners[i];
            if (holder != address(0) && perNFT > 0) {
                super._transfer(address(this), holder, perNFT);
            }
        }
        emit NFTDividendDistributed(nftRewardPool, perNFT);
    }

    // ==================== NFT 铸造 ====================
    function mintNFT(address to) external onlyOwner {
        require(nftTotalMinted < MAX_NFT_SUPPLY, "max 30 NFTs minted");
        uint256 tokenId = nftTotalMinted + 1;

        nftOwners[tokenId] = to;
        nftBalances[to] += 1;
        nftTotalMinted++;
        emit NFTMinted(to, tokenId);
    }

    function batchMintNFT(address[] calldata recipients) external onlyOwner {
        require(nftTotalMinted + recipients.length <= MAX_NFT_SUPPLY, "exceeds max supply");
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 tokenId = nftTotalMinted + 1;
            nftOwners[tokenId] = recipients[i];
            nftBalances[recipients[i]] += 1;
            nftTotalMinted++;
            emit NFTMinted(recipients[i], tokenId);
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(tokenId >= 1 && tokenId <= MAX_NFT_SUPPLY, "invalid tokenId");
        return nftOwners[tokenId];
    }

    function nftBalanceOf(address owner) external view returns (uint256) {
        return nftBalances[owner];
    }

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }
    
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(nftOwners[tokenId] != address(0), "nonexistent token");
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId), ".json"));
    }
    function completeBind(address downline, address up) public {
        require(msg.sender == address(this), "only internal");
        require(referrers[downline] == address(0), "already bound");
        require(downline != up, "cannot bind to self");

        referrers[downline] = up;
        emit BoundReferrer(downline, up);

        if (balanceOf(address(this)) >= 3 * 10**18) {
            super._transfer(address(this), downline, 2 * 10**18);
            super._transfer(address(this), up, 1 * 10**18);
        }
    }

    // ==================== 工具函数 ====================
    function setLPDividendThreshold(uint256 _amount) external onlyOwner {
        lpDividendThreshold = _amount;
    }

    function setNFTDividendThreshold(uint256 _amount) external onlyOwner {
        nftDividendThreshold = _amount;
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
    
    function getReferrer(address user) public view returns (address) {
        return referrers[user];
    }

    receive() external payable {}
}