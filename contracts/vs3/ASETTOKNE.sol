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
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function removeLiquidity(address tokenA, address tokenB, uint liquidity, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB);
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

interface IAutoStake {
    function completeBind(address downline, address up) external;
    function getReferrer(address user) external view returns (address);
}

interface ASTERDAONFT {
    function mint(address to) external;
    function batchMint(address[] calldata recipients) external;
    function distributeDividends(uint256 perNFT) external;
}

contract ASTERDAO is ERC20, Ownable, ReentrancyGuard {

    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TAX_RATE = 2000;
    uint256 public constant BIND_AMOUNT = 2 * 1e18;
    uint256 public constant BACK_AMOUNT = 1 * 1e18;

    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_UNITS = 10;
    uint256 public constant TIME_UNIT = 60;

    address public constant REAL_ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    mapping(address => uint256) public lpReceiveTime;

    uint256 public previousDayPrice;
    uint256 public lastPriceCheckTimestamp;

    mapping(address => StakeInfo) public stakes;
    mapping(address => address) public referrers;
    mapping(address => bool) public isEffectiveUser;

    uint256 public totalStaked;
    uint256 public minEffectiveUSD = 0.01 * 1e18;
    uint256 public maxStakePerUserUSD = 5000 * 1e18;

    IERC20 public lpToken;

    uint256 public lpDividendPool;
    uint256 public nftRewardPool;
    uint256 public lpDividendThreshold = 5000 * 1e18;
    uint256 public nftDividendThreshold = 300 * 1e18;

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 autoRewardUntil;
        address referrer;
        bool active;
    }

    struct LPStakeInfo {
        uint256 amount;
        uint256 stakeTime;
        uint256 lastClaimTime;
    }

    event TaxDistributed(uint256 totalTax, uint256 nftShare, uint256 lpShare, uint256 burnShare, uint256 lpPoolShare, uint256 mktShare);
    event BindEvent(address indexed down, address indexed up);
    event Staked(address indexed user, uint256 amount, bool isEffective, bool isAuto);
    event RewardClaimed(address indexed user, uint256 userNet, uint256 referralDistributed, uint256 periodsClaimed, bool wasEffective);
    event Redeemed(address indexed user, uint256 returnedAmount, uint256 burnedAmount, uint256 penaltyRate);
    event LPDividendDistributed(address indexed user, uint256 amount);
    event NFTDividendDistributed(uint256 totalAmount, uint256 perNFT);
    event BuybackToRealASTER(uint256 projectTokenUsed, uint256 realASTERBought);
    event BoundReferrer(address indexed user, address indexed referrer);
    event TradingEnabledUpdated(bool enabled);
    event PriceAndTaxUpdated(uint256 currentPrice, uint256 effectiveTaxRate, bool dropDetected);
    event LPStaked(address indexed user, uint256 amount);
    event LPUnstaked(address indexed user, uint256 amount, bool earlyWithdraw);
    event EffectiveUserUpdated(address indexed user, bool status);
    event AutoRewardActivated(address indexed user, uint256 periods, uint256 newUntil);
    event ReferralBonusPaid(address indexed referrer, address indexed downline, uint256 amount, uint8 level);
    event LPDistributedToPartner(address indexed partner, uint256 amount);

    constructor(address _router, address _projectTreasury) ERC20("ASTERDAO", "ASTER") Ownable() {
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

    function setAddresses(address _marketing, address _nft, address _lp, address _lpPool, address _project) external onlyOwner {
        require(_marketing != address(0) && _nft != address(0) && _lp != address(0) && _lpPool != address(0) && _project != address(0), "zero address");
        marketingAddress = _marketing;
        nftAddress = _nft;
        lpAddress = _lp;
        lpPoolAddress = _lpPool;
        projectAddress = _project;
    }

    function setLPToken(address _lpToken) external onlyOwner {
        require(_lpToken != address(0), "zero address");
        lpToken = IERC20(_lpToken);
    }

    function setPairAddress(address _pair) external onlyOwner {
        require(_pair != address(0), "pair zero");
        pairAddress = _pair;
    }

    function setBnbUsdtPairAddress(address _pair) external onlyOwner {
        require(_pair != address(0), "pair zero");
        bnbUsdtPairAddress = _pair;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabledUpdated(true);
    }

    function getPairReserves() public view returns (uint256 reserveASTER, uint256 reserveWBNB) {
        if (pairAddress == address(0)) return (0, 0);
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        address token0 = pair.token0();
        if (token0 == address(this)) {
            return (reserve0, reserve1);
        } else {
            return (reserve1, reserve0);
        }
    }

    function getCurrentPrice() public view returns (uint256) {
        if (pairAddress == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        address token0 = pair.token0();
        return token0 == address(this) ? (uint256(reserve1) * 1e18) / reserve0 : (uint256(reserve0) * 1e18) / reserve1;
    }

    function getBnbPriceInUSD() public view returns (uint256) {
        if (bnbUsdtPairAddress == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(bnbUsdtPairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        address token0 = pair.token0();
        return token0 == WBNB ? (uint256(reserve1) * 1e18) / reserve0 : (uint256(reserve0) * 1e18) / reserve1;
    }

    function getUSDValue(uint256 amount) public view returns (uint256) {
        uint256 p1 = getCurrentPrice();
        uint256 p2 = getBnbPriceInUSD();
        if (p1 == 0 || p2 == 0) return 0;
        return (amount * p1 * p2) / 1e36;
    }

    function updatePriceAndTax() external nonReentrant {
        if (pairAddress == address(0) || !priceDropProtectionEnabled) return;
        uint256 currentPrice = getCurrentPrice();
        if (currentPrice == 0) return;

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

    function _transfer(address from, address to, uint256 amount) internal override {
        if (amount == 1 * 1e18 && stakes[from].active) {
            uint256 reward = pendingReward(from);
            if (reward > 0) {
                _payRewardFromBottomPool(from, reward);
                emit RewardClaimed(from, reward, 0, 0, isEffectiveUser[from]);
            }
            stakes[from].lastClaimTime = block.timestamp;
            stakes[from].autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
            emit AutoRewardActivated(from, 10, stakes[from].autoRewardUntil);
            return;
        }

        if (amount == 10 * 1e18 && stakes[from].active) {
            // 执行赎回逻辑
            _executeRedeem(from);
            return;
        }
        if (stakingContract != address(0)) {
            if (amount == BIND_AMOUNT && !preUps[to][from]) preUps[from][to] = true;
            if (amount == BACK_AMOUNT && preUps[to][from] && IAutoStake(stakingContract).getReferrer(from) == address(0)) {
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
            _autoStake(from, amount);   // 正常自动质押
        }
    }

    function _executeRedeem(address user) internal {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.active || userStake.amount == 0) return;

        uint256 principal = userStake.amount;
        if (totalStaked >= principal) totalStaked -= principal;
        else totalStaked = 0;

        uint256 periodsStaked = (block.timestamp - userStake.startTime) / TIME_UNIT;
        uint256 returnRate = periodsStaked <= 10 ? 70 : (periodsStaked <= 20 ? 80 : (periodsStaked <= 30 ? 90 : 100));

        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        userStake.active = false;
        userStake.amount = 0;
        userStake.autoRewardUntil = 0;

        if (returnAmount > 0) super._transfer(address(this), user, returnAmount);
        if (burnAmount > 0) super._transfer(address(this), DEAD, burnAmount);

        emit Redeemed(user, returnAmount, burnAmount, returnRate);
}

    function _distributeTax(address from, uint256 taxAmount) internal {
        if (taxAmount == 0) return;
        uint256 nftShare = (taxAmount * 20) / 100;
        uint256 lpShare = (taxAmount * 40) / 100;
        uint256 burnShare = (taxAmount * 5) / 100;
        uint256 lpPoolShare = (taxAmount * 5) / 100;
        uint256 mktShare = (taxAmount * 30) / 100;

        if (nftShare > 0) super._transfer(from, nftAddress, nftShare);
        if (burnShare > 0) super._transfer(from, DEAD, burnShare);
        if (lpPoolShare > 0) super._transfer(from, lpPoolAddress, lpPoolShare);
        if (mktShare > 0) super._transfer(from, marketingAddress, mktShare);

        if (lpShare > 0) {
            super._transfer(from, address(this), lpShare);
            _autoSwapToRealASTER(lpShare);
        }

        emit TaxDistributed(taxAmount, nftShare, lpShare, burnShare, lpPoolShare, mktShare);
    }

    function _autoSwapToRealASTER(uint256 amountIn) internal {
        if (amountIn == 0) return;
        _approve(address(this), PANCAKE_ROUTER, amountIn);

        address[] memory path1 = new address[](2);
        path1[0] = address(this);
        path1[1] = WBNB;

        try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(amountIn, 0, path1, address(this), block.timestamp + 300) returns (uint[] memory amounts) {
            uint256 wbnbAmount = amounts[1];
            address[] memory path2 = new address[](2);
            path2[0] = WBNB;
            path2[1] = REAL_ASTER;
            try IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(wbnbAmount, 0, path2, address(this), block.timestamp + 300) returns (uint[] memory amounts2) {
                lpDividendPool += amounts2[1];
            } catch {}
        } catch {}
    }

    function _autoStake(address user, uint256 amount) internal {
        if (amount == 0) return;
        if (amount == 1 * 1e18 && stakes[user].active) {
            // 先计算奖励
            uint256 reward = pendingReward(user);
            if (reward > 0) {
                _payRewardFromBottomPool(user, reward);
                emit RewardClaimed(user, reward, 0, 0, isEffectiveUser[user]);
            }
            stakes[user].lastClaimTime = block.timestamp;
            stakes[user].autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
            emit AutoRewardActivated(user, 10, stakes[user].autoRewardUntil);
            return;
        }
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

    // function _autoStake(address user, uint256 amount) internal {
    //     if (amount == 0) return;
    //     if (amount == 1 * 1e18 && stakes[user].active) {
    //         stakes[user].lastClaimTime = block.timestamp;
    //         uint256 reward = pendingReward(user);
    //         if (reward > 0) {
    //             _payRewardFromBottomPool(user, reward);
    //             emit RewardClaimed(user, reward, 0, 0, isEffectiveUser[user]);
    //         }
    //         stakes[user].autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
    //         emit AutoRewardActivated(user, 10, stakes[user].autoRewardUntil);
    //         return;
    //     }

    //     if (stakes[user].active) revert("already staking, please redeem first");

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

    function getCurrentRate() public view returns (uint256) {
        uint256 poolSize = getBottomPoolASTERAmount();
        if (poolSize > 1_000_000_000e18) return 150;
        if (poolSize > 500_000_000e18) return 120;
        if (poolSize > 100_000_000e18) return 100;
        if (poolSize > 10_000_000e18) return 80;
        return 50;
    }

    function getBottomPoolASTERAmount() public view returns (uint256) {
        if (address(lpToken) == address(0) || lpPoolAddress == address(0) || pairAddress == address(0)) return 0;
        uint256 lpBalance = lpToken.balanceOf(lpPoolAddress);
        if (lpBalance == 0) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        uint256 totalLPSupply = pair.totalSupply();
        if (totalLPSupply == 0) return 0;
        (uint256 reserveASTER, ) = getPairReserves();
        return (reserveASTER * lpBalance) / totalLPSupply;
    }

    function getBottomPoolInfo() public view returns (uint256 aster, uint256 wbnb, uint256 rate) {
        (uint256 r0, uint256 r1) = getPairReserves();
        return (r0, r1, getCurrentRate());
    }

    function getMyInfo(address user) public view returns (uint256 staked, uint256 pending, uint256 lastClaim) {
        StakeInfo storage s = stakes[user];
        return (s.amount, pendingReward(user), s.lastClaimTime);
    }

    function pendingReward(address user) public view returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.active) return 0;
        uint256 rate = getCurrentRate();
        if (rate == 0) return 0;
        uint256 periodsPassed = (block.timestamp - userStake.lastClaimTime) / TIME_UNIT;
        if (periodsPassed == 0) return 0;
        periodsPassed = periodsPassed > STAKE_PERIOD_UNITS ? STAKE_PERIOD_UNITS : periodsPassed;
        uint256 grossReward = (userStake.amount * rate * periodsPassed) / 10000;
        uint256 referralTotal = 0;
        if (userStake.referrer != address(0) && isEffectiveUser[user]) {
            referralTotal = _calculateNewReferralRewards(grossReward, userStake.referrer);
        }
        uint256 userNet = grossReward - referralTotal;
        if (userNet < 0) userNet = 0;
        return userNet;
    }

    function _removeLiquidityFromBottomPool(uint256 targetAmount) internal returns (uint256 asterGot, uint256 wbnbGot) {
        uint256 availableLP = IERC20(pairAddress).balanceOf(lpPoolAddress);
        if (availableLP == 0) return (0, 0);

        uint256 lpToRemove = (targetAmount * availableLP) / getBottomPoolASTERAmount();
        if (lpToRemove > availableLP * 5 / 100) lpToRemove = availableLP * 5 / 100;
        if (lpToRemove == 0) lpToRemove = 1;

        IERC20(pairAddress).transferFrom(lpPoolAddress, address(this), lpToRemove);
        IERC20(pairAddress).approve(PANCAKE_ROUTER, lpToRemove);

        (uint amountToken, uint amountWBNB) = IUniswapV2Router02(PANCAKE_ROUTER).removeLiquidity(
            address(this), WBNB, lpToRemove, 0, 0, address(this), block.timestamp + 300
        );

        return (amountToken, amountWBNB);
    }

    function _payRewardFromBottomPool(address user, uint256 amount) internal {
        if (amount == 0) return;
        (uint256 asterGot, uint256 wbnbGot) = _removeLiquidityFromBottomPool(amount);
        if (asterGot > 0) super._transfer(address(this), user, asterGot);
        if (wbnbGot > 0) {
            IERC20(WBNB).approve(PANCAKE_ROUTER, wbnbGot);
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = USDT;
            IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(wbnbGot, 0, path, user, block.timestamp + 300);
        }
    }

    function _fundPoolsFromBottomPool(uint256 amount) internal {
        if (amount == 0) return;
        (uint256 asterGot, ) = _removeLiquidityFromBottomPool(amount);
        if (asterGot > 0) {
            lpDividendPool += (asterGot * 10) / 12;
            nftRewardPool += (asterGot * 2) / 12;
        }
    }

    function _calculateNewReferralRewards(uint256 gross, address startReferrer) internal view returns (uint256 total) {
        address current = startReferrer;
        uint8 gen = 1;
        while (current != address(0) && gen <= 16) {
            uint256 rate = (gen == 1) ? 1000 : (gen == 2) ? 600 : (gen <= 5) ? 400 : 200;
            total += (gross * rate) / 10000;
            current = referrers[current];
            gen++;
        }
        return total;
    }

    function _distributeNewReferralRewards(address downline, uint256 totalReferral, address startReferrer) internal {
        address current = startReferrer;
        uint8 gen = 1;
        uint256 remaining = totalReferral;
        while (current != address(0) && gen <= 16 && remaining > 0) {
            uint256 rate = (gen == 1) ? 1000 : (gen == 2) ? 600 : (gen <= 5) ? 400 : 200;
            uint256 share = (totalReferral * rate) / 10000;
            if (share > remaining) share = remaining;
            if (share > 0) {
                _payRewardFromBottomPool(current, share);
                emit ReferralBonusPaid(current, downline, share, gen);
                remaining -= share;
            }
            current = referrers[current];
            gen++;
        }
        if (remaining > 0 && projectTreasury != address(0)) {
            _payRewardFromBottomPool(projectTreasury, remaining);
        }
    }

    function redeem() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");
        require(userStake.amount > 0, "no stake amount");

        uint256 principal = userStake.amount;
        if (totalStaked >= principal) totalStaked -= principal;
        else totalStaked = 0;

        uint256 periodsStaked = (block.timestamp - userStake.startTime) / TIME_UNIT;
        uint256 returnRate = periodsStaked <= 10 ? 70 : (periodsStaked <= 20 ? 80 : (periodsStaked <= 30 ? 90 : 100));

        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        userStake.active = false;
        userStake.amount = 0;
        userStake.autoRewardUntil = 0;

        if (returnAmount > 0) super._transfer(address(this), msg.sender, returnAmount);
        if (burnAmount > 0) super._transfer(address(this), DEAD, burnAmount);

        emit Redeemed(msg.sender, returnAmount, burnAmount, returnRate);
    }

    function _checkMaxStake(address user, uint256 newAmount) internal view {
        uint256 currentStakeUSD = getUSDValue(stakes[user].amount);
        uint256 newStakeUSD = getUSDValue(newAmount);
        require(currentStakeUSD + newStakeUSD <= maxStakePerUserUSD, "Exceeds max stake per user (USD limit)");
    }

    function stakeLP(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        lpToken.transferFrom(msg.sender, address(this), amount);
        LPStakeInfo storage stake = lpStakes[msg.sender];
        if (stake.amount == 0) stake.stakeTime = block.timestamp;
        stake.amount += amount;
        emit LPStaked(msg.sender, amount);
    }

    function unstakeLP() external {
        LPStakeInfo storage stake = lpStakes[msg.sender];
        require(stake.amount > 0, "No LP staked");
        uint256 amount = stake.amount;
        uint256 daysStaked = (block.timestamp - stake.stakeTime) / 1 days;
        bool isEarlySpecial = isSpecialLPUser[msg.sender] && daysStaked < 100;

        if (isEarlySpecial) {
            _handleEarlyUnstake(msg.sender, amount);
            emit LPUnstaked(msg.sender, amount, true);
        } else {
            _handleFullUnstake(msg.sender, amount);
            emit LPUnstaked(msg.sender, amount, false);
        }
        delete lpStakes[msg.sender];
    }

    function _handleEarlyUnstake(address user, uint256 lpAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(PANCAKE_ROUTER);
        lpToken.approve(PANCAKE_ROUTER, lpAmount);
        (uint amountToken, uint amountBNB) = router.removeLiquidity(address(this), WBNB, lpAmount, 0, 0, address(this), block.timestamp + 300);
        if (amountToken > 0) super._transfer(address(this), DEAD, amountToken);
        if (amountBNB > 0) {
            IERC20(WBNB).approve(PANCAKE_ROUTER, amountBNB);
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = USDT;
            router.swapExactTokensForTokens(amountBNB, 0, path, user, block.timestamp + 300);
        }
    }

    function _handleFullUnstake(address user, uint256 lpAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(PANCAKE_ROUTER);
        lpToken.approve(PANCAKE_ROUTER, lpAmount);
        router.removeLiquidity(address(this), WBNB, lpAmount, 0, 0, user, block.timestamp + 300);
    }

    function distributeLPDividends(address[] calldata users) external onlyOwner {
        uint256 totalDividend = lpDividendPool;
        require(totalDividend > 0, "No dividend to distribute");
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < users.length; i++) totalWeight += getUserLPValueInUSDT(users[i]);
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

    function distributeLPToPartner(address partner, uint256 lpAmount) external onlyOwner {
        require(lpToken.balanceOf(address(this)) >= lpAmount, "insufficient LP balance");
        require(partner != address(0), "zero address");
        lpToken.transfer(partner, lpAmount);
        isSpecialLPUser[partner] = true;
        lpReceiveTime[partner] = block.timestamp;
        emit LPDistributedToPartner(partner, lpAmount);
    }

    function removeLiquidityControlled(uint256 lpAmount) external nonReentrant {
        require(lpAmount > 0, "Amount must be greater than 0");
        require(lpReceiveTime[msg.sender] > 0, "You did not receive LP from the project");
        require(lpToken.balanceOf(msg.sender) >= lpAmount, "Insufficient LP balance");

        uint256 holdingDays = (block.timestamp - lpReceiveTime[msg.sender]) / 1 days;
        bool isEarly = holdingDays < 100;

        lpToken.transferFrom(msg.sender, address(this), lpAmount);
        IUniswapV2Router02 router = IUniswapV2Router02(PANCAKE_ROUTER);
        lpToken.approve(PANCAKE_ROUTER, lpAmount);

        (uint amountToken, uint amountBNB) = router.removeLiquidity(address(this), WBNB, lpAmount, 0, 0, address(this), block.timestamp + 300);

        if (isEarly) {
            if (amountToken > 0) super._transfer(address(this), DEAD, amountToken);
            if (amountBNB > 0) {
                IERC20(WBNB).approve(PANCAKE_ROUTER, amountBNB);
                address[] memory path = new address[](2);
                path[0] = WBNB;
                path[1] = USDT;
                router.swapExactTokensForTokens(amountBNB, 0, path, msg.sender, block.timestamp + 300);
            }
        } else {
            if (amountToken > 0) super._transfer(address(this), msg.sender, amountToken);
            if (amountBNB > 0) IERC20(WBNB).transfer(msg.sender, amountBNB);
        }
    }

    function buybackToRealASTER(uint256 amountIn) external onlyOwner {
        require(amountIn > 0 && balanceOf(address(this)) >= amountIn, "insufficient balance");
        _approve(address(this), PANCAKE_ROUTER, amountIn);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = REAL_ASTER;
        uint[] memory amounts = IUniswapV2Router02(PANCAKE_ROUTER).swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp + 300);
        uint256 bought = amounts[1];
        lpDividendPool += bought;
        emit BuybackToRealASTER(amountIn, bought);
    }

    function distributeNFTDividends() external {
        require(nftRewardPool >= nftDividendThreshold, "below threshold");
        uint256 perNFT = nftRewardPool / 30;
        nftRewardPool = 0;
        if (nftAddress != address(0)) ASTERDAONFT(nftAddress).distributeDividends(perNFT);
        emit NFTDividendDistributed(0, perNFT);
    }

    function mintNFT(address to) external onlyOwner {
        require(nftAddress != address(0), "NFT contract not set");
        ASTERDAONFT(nftAddress).mint(to);
    }

    function batchMintNFT(address[] calldata recipients) external onlyOwner {
        require(nftAddress != address(0), "NFT contract not set");
        ASTERDAONFT(nftAddress).batchMint(recipients);
    }

    function rescueToken(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "Cannot rescue self token");
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    receive() external payable {}
}