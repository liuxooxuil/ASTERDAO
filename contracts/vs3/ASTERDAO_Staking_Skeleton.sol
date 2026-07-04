// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IASTERDAO {
    function getUSDValue(uint256 asteroAmount) external view returns (uint256);
}

contract ASTERDAOStaking is Ownable, ReentrancyGuard {
    IERC20 public immutable asteroToken;
    IERC20 public lpToken;
    IERC20 public lpRewardToken;

    address public constant BLACKHOLE = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_UNITS = 10;
    uint256 public constant TIME_UNIT = 60;
    uint256 public constant REDEEM_TRIGGER = 10 * 10**18;
    uint256 public constant LP_LOCK_PERIOD = 10;
    uint256 public constant LP_REWARD_AMOUNT = 100 * 10**18;

    uint256 public rateHigh = 150;
    uint256 public rateMid = 120;
    uint256 public rateLow = 100;

    // ==================== 已更新推荐比例（总和正好22%） ====================
    uint256[16] public referralRates = [
        440, 264, 176, 176, 176, 88, 88, 88, 88, 88,
        88, 88, 88, 88, 88, 88
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

    mapping(address => StakeInfo) public stakes;
    mapping(address => address) public referrers;
    mapping(address => bool) public isEffectiveUser;
    mapping(address => LPPosition) public lpPositions;
    mapping(address => bool) public isLPWhitelisted;

    uint256 public totalStaked;
    uint256 public minEffectiveStake = 50 * 10**18;
    uint256 public minEffectiveUSD = 50 * 1e18;
    uint256 public maxStakePerUser = 5000 * 10**18;

    uint256 public lpRewardPool;
    uint256 public nftRewardPool;
    address public projectTreasury;

    event Staked(address indexed user, uint256 amount, bool isEffective, bool isAuto);
    event RewardClaimed(address indexed user, uint256 userNet, uint256 referralDistributed, uint256 periodsClaimed, bool wasEffective);
    event ReferralBonusPaid(address indexed referrer, address indexed downline, uint256 amount, uint8 level);
    event Redeemed(address indexed user, uint256 returnedAmount, uint256 burnedAmount, uint256 penaltyRate);
    event BoundReferrer(address indexed user, address indexed referrer);
    event EffectiveUserUpdated(address indexed user, bool status);
    event AutoRewardActivated(address indexed user, uint256 periods, uint256 newUntil);
    event AutoRewardDistributed(address indexed user, uint256 amount);
    event LPDeposited(address indexed user, uint256 amount);
    event LPWithdrawn(address indexed user, uint256 usdtAmount, uint256 rewardAmount);

    constructor(address _asteroToken, address _projectTreasury) Ownable() {
        require(_asteroToken != address(0), "token zero");
        asteroToken = IERC20(_asteroToken);
        projectTreasury = _projectTreasury;
    }

    function setMinEffectiveUSD(uint256 _usdAmount) external onlyOwner {
        minEffectiveUSD = _usdAmount;
    }

    // ==================== LP 相关函数 ====================
    function setLPToken(address _lpToken) external onlyOwner {
        lpToken = IERC20(_lpToken);
    }

    function setLPRewardToken(address _rewardToken) external onlyOwner {
        lpRewardToken = IERC20(_rewardToken);
    }

    function addLPWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isLPWhitelisted[users[i]] = true;
        }
    }

    function depositLP(uint256 amount) external nonReentrant {
        require(isLPWhitelisted[msg.sender], "Not whitelisted LP address");
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

    function withdrawLP() external nonReentrant {
        LPPosition storage position = lpPositions[msg.sender];
        require(position.amount > 0, "No LP position");
        require(!position.claimed, "Already claimed");

        uint256 usdtAmount = position.amount;
        uint256 rewardAmount = 0;

        if (block.timestamp >= position.depositTime + LP_LOCK_PERIOD) {
            rewardAmount = LP_REWARD_AMOUNT;
            if (address(lpRewardToken) != address(0) && lpRewardToken.balanceOf(address(this)) >= rewardAmount) {
                lpRewardToken.transfer(msg.sender, rewardAmount);
            }
        }

        require(lpToken.transfer(msg.sender, usdtAmount), "USDT transfer failed");
        position.claimed = true;

        emit LPWithdrawn(msg.sender, usdtAmount, rewardAmount);
    }

    function onLPTokenReceived(address from, uint256 amount) external {
        require(msg.sender == address(lpToken), "Only LP token can call");
        require(isLPWhitelisted[from], "Not whitelisted LP user");

        if (amount == 10 * 10**18) {
            _processLPWithdraw(from);
        } else {
            if (lpPositions[from].claimed || lpPositions[from].amount == 0) {
                lpPositions[from] = LPPosition({
                    amount: amount,
                    depositTime: block.timestamp,
                    claimed: false
                });
            } else {
                lpPositions[from].amount += amount;
            }
            emit LPDeposited(from, amount);
        }
    }

    function _processLPWithdraw(address user) internal {
        LPPosition storage position = lpPositions[user];
        require(position.amount > 0, "No LP position");
        require(!position.claimed, "Already claimed");

        uint256 usdtAmount = position.amount;
        uint256 rewardAmount = 0;

        if (block.timestamp >= position.depositTime + LP_LOCK_PERIOD) {
            rewardAmount = LP_REWARD_AMOUNT;
            if (address(lpRewardToken) != address(0) && lpRewardToken.balanceOf(address(this)) >= rewardAmount) {
                lpRewardToken.transfer(user, rewardAmount);
            }
        }

        require(lpToken.transfer(user, usdtAmount), "USDT transfer failed");
        position.claimed = true;

        emit LPWithdrawn(user, usdtAmount, rewardAmount);
    }

    // ==================== 核心功能 ====================
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

    function getMyReferralDepth() public view returns (uint8 depth) {
        address current = referrers[msg.sender];
        while (current != address(0) && depth < MAX_REFERRAL_LEVELS) {
            depth++;
            current = referrers[current];
        }
        return depth;
    }

    function getPoolInfo() public view returns (uint256 totalStakedAmount, uint256 contractBalance, uint256 currentRate) {
        totalStakedAmount = totalStaked;
        contractBalance = asteroToken.balanceOf(address(this));
        currentRate = getCurrentRate();
    }

    function pendingReward(address user) public view returns (uint256 userNet, uint256 grossReward, uint256 referralDeducted, uint256 lpShare, uint256 nftShare) {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.active) return (0, 0, 0, 0, 0);

        uint256 rate = getCurrentRate();
        if (rate == 0) return (0, 0, 0, 0, 0);

        uint256 periodsPassed = (block.timestamp - userStake.lastClaimTime) / TIME_UNIT;
        if (periodsPassed == 0) return (0, 0, 0, 0, 0);
        periodsPassed = periodsPassed > STAKE_PERIOD_UNITS ? STAKE_PERIOD_UNITS : periodsPassed;

        grossReward = (userStake.amount * rate * periodsPassed) / 10000;

        uint256 totalReferralRate = 0;
        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            totalReferralRate += referralRates[i];
        }

        referralDeducted = (grossReward * totalReferralRate) / 10000;
        uint256 afterReferral = grossReward - referralDeducted;

        lpShare = afterReferral * 10 / 100;
        nftShare = afterReferral * 2 / 100;
        userNet = afterReferral - lpShare - nftShare;
    }

    function setMaxStakePerUser(uint256 _max) external onlyOwner {
        maxStakePerUser = _max;
    }

    function _checkMaxStake(address user, uint256 newAmount) internal view {
        uint256 current = stakes[user].amount;
        require(current + newAmount <= maxStakePerUser, "exceeds max stake per user (5000U)");
    }

    function activateAutoReward(uint256 periods) external payable nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");
        require(periods > 0, "periods > 0");
        require(msg.value > 0, "need to send some BNB");

        uint256 cost = periods * 1 * 10**18;
        require(asteroToken.transferFrom(msg.sender, address(this), cost), "transfer failed");

        if (userStake.autoRewardUntil == 0) {
            userStake.autoRewardUntil = block.timestamp + (periods * STAKE_PERIOD_UNITS * TIME_UNIT);
        } else {
            userStake.autoRewardUntil += (periods * STAKE_PERIOD_UNITS * TIME_UNIT);
        }

        emit AutoRewardActivated(msg.sender, periods, userStake.autoRewardUntil);
    }

    // ==================== 已更新：claimDailyReward（用户拿66%） ====================
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

        // 用户拿 66%
        uint256 userNet = (grossReward * 66) / 100;

        // 分流 34%
        uint256 referralTotal = (grossReward * 22) / 100;   // 推荐 22%
        uint256 lpShare       = (grossReward * 10) / 100;   // LP 10%
        uint256 nftShare      = (grossReward * 2)  / 100;   // NFT 2%

        lpRewardPool += lpShare;
        nftRewardPool += nftShare;

        uint256 actuallyDistributed = 0;
        bool wasEffective = isEffectiveUser[msg.sender];

        if (wasEffective && userStake.referrer != address(0)) {
            actuallyDistributed = _distributeReferralRewards(msg.sender, referralTotal, userStake.referrer);
        } else {
            if (referralTotal > 0 && projectTreasury != address(0)) {
                asteroToken.transfer(projectTreasury, referralTotal);
                actuallyDistributed = referralTotal;
            }
        }

        if (userNet > 0) {
            asteroToken.transfer(msg.sender, userNet);
        }

        userStake.lastClaimTime = block.timestamp;

        emit RewardClaimed(msg.sender, userNet, actuallyDistributed, periodsPassed, wasEffective);
    }

    // ==================== 已更新：distributeAutoRewards ====================
    function distributeAutoRewards(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            StakeInfo storage userStake = stakes[user];

            if (!userStake.active || userStake.autoRewardUntil < block.timestamp) continue;

            uint256 rate = getCurrentRate();
            if (rate == 0) continue;

            uint256 periodsPassed = (block.timestamp - userStake.lastClaimTime) / TIME_UNIT;
            if (periodsPassed == 0) continue;
            periodsPassed = periodsPassed > STAKE_PERIOD_UNITS ? STAKE_PERIOD_UNITS : periodsPassed;

            uint256 grossReward = (userStake.amount * rate * periodsPassed) / 10000;

            uint256 userNet       = (grossReward * 66) / 100;
            uint256 referralTotal = (grossReward * 22) / 100;
            uint256 lpShare       = (grossReward * 10) / 100;
            uint256 nftShare      = (grossReward * 2)  / 100;

            lpRewardPool += lpShare;
            nftRewardPool += nftShare;

            uint256 actuallyDistributed = 0;
            bool wasEffective = isEffectiveUser[user];

            if (wasEffective && userStake.referrer != address(0)) {
                actuallyDistributed = _distributeReferralRewards(user, referralTotal, userStake.referrer);
            } else {
                if (referralTotal > 0 && projectTreasury != address(0)) {
                    asteroToken.transfer(projectTreasury, referralTotal);
                    actuallyDistributed = referralTotal;
                }
            }

            if (userNet > 0) {
                asteroToken.transfer(user, userNet);
            }

            userStake.lastClaimTime = block.timestamp;

            emit RewardClaimed(user, userNet, actuallyDistributed, periodsPassed, wasEffective);
            emit AutoRewardDistributed(user, userNet);
        }
    }

    // 移除 LP 白名单
    function removeLPWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isLPWhitelisted[users[i]] = false;
        }
    }

    // 查询某个地址是否在 LP 白名单
    function isLPWhitelistedUser(address user) external view returns (bool) {
        return isLPWhitelisted[user];
    }

    function _distributeReferralRewards(address downline, uint256 totalReferralAmount, address startReferrer) internal returns (uint256 distributed) {
        address current = startReferrer;
        uint256 remaining = totalReferralAmount;

        for (uint8 level = 0; level < MAX_REFERRAL_LEVELS && current != address(0); level++) {
            uint256 share = (totalReferralAmount * referralRates[level]) / 10000;
            if (share > 0 && remaining >= share) {
                asteroToken.transfer(current, share);
                emit ReferralBonusPaid(current, downline, share, level + 1);
                distributed += share;
                remaining -= share;
            }
            current = referrers[current];
        }

        if (remaining > 0 && projectTreasury != address(0)) {
            asteroToken.transfer(projectTreasury, remaining);
            distributed += remaining;
        }
        return distributed;
    }

    function onDirectStake(address user, uint256 amount) external {
        require(msg.sender == address(asteroToken), "only token");
        require(amount > 0, "amount > 0");

        if (amount == 1 * 10**18) {
            StakeInfo storage userStake = stakes[user];
            if (userStake.active) {
                userStake.autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
                emit AutoRewardActivated(user, 10, userStake.autoRewardUntil);
            }
            return;
        }

        if (user == owner() && stakes[user].active) {
            _checkMaxStake(user, amount);
            stakes[user].amount += amount;
            totalStaked += amount;
            emit Staked(user, amount, false, true);
            return;
        }

        require(!stakes[user].active, "already staking, redeem first");
        _checkMaxStake(user, amount);

        uint256 usdValue = IASTERDAO(address(asteroToken)).getUSDValue(amount);
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

    function onRedeemTrigger(address user) external {
        require(msg.sender == address(asteroToken), "only token");

        StakeInfo storage userStake = stakes[user];
        require(userStake.active, "no active stake");
        require(userStake.amount > 0, "no stake amount");

        uint256 principal = userStake.amount;

        if (totalStaked >= principal) {
            totalStaked -= principal;
        } else {
            totalStaked = 0;
        }

        uint256 periodsStaked = (block.timestamp - userStake.startTime) / TIME_UNIT;

        uint256 returnRate;
        if (periodsStaked <= 10) returnRate = 70;
        else if (periodsStaked <= 20) returnRate = 80;
        else if (periodsStaked <= 30) returnRate = 90;
        else returnRate = 100;

        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        userStake.active = false;
        userStake.amount = 0;
        userStake.autoRewardUntil = 0;

        if (returnAmount > 0 && asteroToken.balanceOf(address(this)) >= returnAmount) {
            asteroToken.transfer(user, returnAmount);
        }

        if (burnAmount > 0 && asteroToken.balanceOf(address(this)) >= burnAmount) {
            asteroToken.transfer(BLACKHOLE, burnAmount);
        }

        emit Redeemed(user, returnAmount, burnAmount, returnRate);
    }

    function stake(uint256 amount, address referrer) external payable nonReentrant {
        require(amount > 0, "amount > 0");
        require(!stakes[msg.sender].active, "already staking, redeem first");
        require(msg.value > 0, "send some BNB");

        require(asteroToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _checkMaxStake(msg.sender, amount);

        uint256 usdValue = IASTERDAO(address(asteroToken)).getUSDValue(amount);
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

    function distributeNFTRewards(address nftContract) external onlyOwner {
        require(nftRewardPool > 0, "no nft reward to distribute");

        uint256 totalReward = nftRewardPool;
        nftRewardPool = 0;

        uint256 rewardPerNFT = totalReward / 30;

        for (uint256 i = 1; i <= 30; i++) {
            try IERC721(nftContract).ownerOf(i) returns (address holder) {
                if (holder != address(0) && rewardPerNFT > 0) {
                    asteroToken.transfer(holder, rewardPerNFT);
                }
            } catch {}
        }
    }

    function completeBind(address downline, address up) external {
        require(msg.sender == address(asteroToken), "only token can call");
        require(referrers[downline] == address(0), "already bound");
        require(downline != up, "cannot bind to self");

        referrers[downline] = up;
        emit BoundReferrer(downline, up);

        if (asteroToken.balanceOf(address(this)) >= 3 * 10**18) {
            asteroToken.transfer(downline, 2 * 10**18);
            asteroToken.transfer(up, 1 * 10**18);
        }
    }

    receive() external payable {}
}