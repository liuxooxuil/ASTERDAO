// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract ASTERDAOStaking is Ownable, ReentrancyGuard {
    IERC20 public immutable asteroToken;
    address public constant BLACKHOLE = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_UNITS = 10;
    uint256 public constant TIME_UNIT = 60; // 测试模式（正式上线改 86400）

    uint256 public constant REDEEM_TRIGGER = 10 * 10**18;

    uint256 public rateHigh = 150;
    uint256 public rateMid = 120;
    uint256 public rateLow = 100;

    uint256[16] public referralRates = [
        1000, 600, 400, 400, 400, 200, 200, 200, 200, 200,
        200, 200, 200, 200, 200, 200
    ];

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 autoRewardUntil;
        address referrer;
        bool active;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => address) public referrers;
    mapping(address => bool) public isEffectiveUser;

    uint256 public totalStaked;
    uint256 public minEffectiveStake = 50 * 10**18;
    uint256 public maxStakePerUser = 5000 * 10**18; // 单地址最大质押量

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

    constructor(address _asteroToken, address _projectTreasury) Ownable() {
        require(_asteroToken != address(0), "token zero");
        asteroToken = IERC20(_asteroToken);
        projectTreasury = _projectTreasury;
    }

    // ==================== VIEW ====================
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

    function getPoolInfo() public view returns (
        uint256 totalStakedAmount,
        uint256 contractBalance,
        uint256 currentRate
    ) {
        totalStakedAmount = totalStaked;
        contractBalance = asteroToken.balanceOf(address(this));
        currentRate = getCurrentRate();
    }

    function pendingReward(address user) public view returns (
        uint256 userNet,
        uint256 grossReward,
        uint256 referralDeducted,
        uint256 lpShare,
        uint256 nftShare
    ) {
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

    // ==================== 设置单地址上限 ====================
    function setMaxStakePerUser(uint256 _max) external onlyOwner {
        maxStakePerUser = _max;
    }

    function _checkMaxStake(address user, uint256 newAmount) internal view {
        uint256 current = stakes[user].amount;
        require(current + newAmount <= maxStakePerUser, "exceeds max stake per user (5000U)");
    }

    // ==================== 自动收益激活 ====================
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

    function distributeAutoRewards(address[] calldata users) external {
    for (uint256 i = 0; i < users.length; i++) {
        address user = users[i];
        StakeInfo storage userStake = stakes[user];

        // 必须是活跃质押 + 自动收益未过期
        if (!userStake.active || userStake.autoRewardUntil < block.timestamp) continue;

        uint256 rate = getCurrentRate();
        if (rate == 0) continue;

        uint256 periodsPassed = (block.timestamp - userStake.lastClaimTime) / TIME_UNIT;
        if (periodsPassed == 0) continue;
        periodsPassed = periodsPassed > STAKE_PERIOD_UNITS ? STAKE_PERIOD_UNITS : periodsPassed;

        uint256 grossReward = (userStake.amount * rate * periodsPassed) / 10000;

        uint256 totalReferralRate = 0;
        for (uint8 j = 0; j < MAX_REFERRAL_LEVELS; j++) {
            totalReferralRate += referralRates[j];
        }

        uint256 referralDeducted = (grossReward * totalReferralRate) / 10000;
        uint256 afterReferral = grossReward - referralDeducted;

        uint256 lpShare = afterReferral * 10 / 100;
        uint256 nftShare = afterReferral * 2 / 100;
        uint256 userNet = afterReferral - lpShare - nftShare;

        lpRewardPool += lpShare;
        nftRewardPool += nftShare;

        uint256 actuallyDistributed = 0;
        bool wasEffective = isEffectiveUser[user];

        if (wasEffective && userStake.referrer != address(0)) {
            actuallyDistributed = _distributeReferralRewards(user, referralDeducted, userStake.referrer);
        } else {
            if (referralDeducted > 0 && projectTreasury != address(0)) {
                asteroToken.transfer(projectTreasury, referralDeducted);
                actuallyDistributed = referralDeducted;
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

    // // ==================== AUTO STAKE（转1个币自动激活） ====================
    // function onDirectStake(address user, uint256 amount) external {
    //     require(msg.sender == address(asteroToken), "only token");
    //     require(amount > 0, "amount > 0");

    //     if (amount == 1 * 10**18) {
    //         StakeInfo storage userStake = stakes[user];
    //         if (userStake.active) {
    //             userStake.autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
    //             emit AutoRewardActivated(user, 10, userStake.autoRewardUntil);
    //         }
    //         return;
    //     }
    //     if (user == owner() && stakes[user].active) {
    //     // 创建者打底池时直接追加，增加 totalStaked
    //     stakes[user].amount += amount;
    //     totalStaked += amount;

    //     emit Staked(user, amount, false, true);
    //     return;
    //     }

    //     require(!stakes[user].active, "already staking, redeem first");
    //     _checkMaxStake(user, amount);

    //     bool makesEffective = amount >= minEffectiveStake;
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

    function onDirectStake(address user, uint256 amount) external {
    require(msg.sender == address(asteroToken), "only token");
    require(amount > 0, "amount > 0");

    // 1. 转正好 1 个币 → 自动激活/延长自动收益
    if (amount == 1 * 10**18) {
        StakeInfo storage userStake = stakes[user];
        if (userStake.active) {
            userStake.autoRewardUntil = block.timestamp + (10 * STAKE_PERIOD_UNITS * TIME_UNIT);
            emit AutoRewardActivated(user, 10, userStake.autoRewardUntil);
        }
        return;
    }

    // 2. 创建者（Owner）已有质押时 → 直接追加（打底池也会增加 totalStaked）
    if (user == owner() && stakes[user].active) {
        _checkMaxStake(user, amount);           // 保留检查
        stakes[user].amount += amount;
        totalStaked += amount;

        emit Staked(user, amount, false, true);
        return;
    }

    // 3. 普通用户逻辑（必须先赎回才能再次质押）
    require(!stakes[user].active, "already staking, redeem first");
    _checkMaxStake(user, amount);

    bool makesEffective = amount >= minEffectiveStake;
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

    // ==================== AUTO REDEEM ====================
    function onRedeemTrigger(address user) external {
        require(msg.sender == address(asteroToken), "only token");
        require(stakes[user].active, "no active stake");

        StakeInfo storage userStake = stakes[user];

        if (asteroToken.balanceOf(address(this)) >= REDEEM_TRIGGER) {
            asteroToken.transfer(BLACKHOLE, REDEEM_TRIGGER);
        }

        uint256 periodsStaked = (block.timestamp - userStake.startTime) / TIME_UNIT;

        uint256 returnRate;
        if (periodsStaked <= 10) returnRate = 70;
        else if (periodsStaked <= 20) returnRate = 80;
        else if (periodsStaked <= 30) returnRate = 90;
        else returnRate = 100;

        uint256 principal = userStake.amount;
        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        totalStaked -= principal;
        userStake.active = false;
        userStake.amount = 0;
        userStake.autoRewardUntil = 0;

        if (returnAmount > 0) asteroToken.transfer(user, returnAmount);
        if (burnAmount > 0) asteroToken.transfer(BLACKHOLE, burnAmount);

        emit Redeemed(user, returnAmount, burnAmount, returnRate);
    }

    // ==================== MANUAL STAKE ====================
    function stake(uint256 amount, address referrer) external payable nonReentrant {
        require(amount > 0, "amount > 0");
        require(!stakes[msg.sender].active, "already staking, redeem first");
        require(msg.value > 0, "send some BNB");

        require(asteroToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _checkMaxStake(msg.sender, amount);

        bool makesEffective = amount >= minEffectiveStake;
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

    // ==================== CLAIM ====================
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

        uint256 totalReferralRate = 0;
        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            totalReferralRate += referralRates[i];
        }

        uint256 referralDeducted = (grossReward * totalReferralRate) / 10000;
        uint256 afterReferral = grossReward - referralDeducted;

        uint256 lpShare = afterReferral * 10 / 100;
        uint256 nftShare = afterReferral * 2 / 100;
        uint256 userNet = afterReferral - lpShare - nftShare;

        lpRewardPool += lpShare;
        nftRewardPool += nftShare;

        uint256 actuallyDistributed = 0;
        bool wasEffective = isEffectiveUser[msg.sender];

        if (wasEffective && userStake.referrer != address(0)) {
            actuallyDistributed = _distributeReferralRewards(msg.sender, referralDeducted, userStake.referrer);
        } else {
            if (referralDeducted > 0 && projectTreasury != address(0)) {
                asteroToken.transfer(projectTreasury, referralDeducted);
                actuallyDistributed = referralDeducted;
            }
        }

        if (userNet > 0) {
            asteroToken.transfer(msg.sender, userNet);
        }

        userStake.lastClaimTime = block.timestamp;

        emit RewardClaimed(msg.sender, userNet, actuallyDistributed, periodsPassed, wasEffective);
    }

    function _distributeReferralRewards(
        address downline,
        uint256 totalReferralAmount,
        address startReferrer
    ) internal returns (uint256 distributed) {
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
    }

    // ==================== NFT 真实分红 ====================
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

    // ==================== 完成绑定 ====================
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