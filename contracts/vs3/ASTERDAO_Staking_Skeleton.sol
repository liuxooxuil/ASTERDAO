// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

contract ASTERDAOStaking is Ownable, ReentrancyGuard {
    IERC20 public immutable asteroToken;
    address public constant BLACKHOLE = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_UNITS = 10;
    uint256 public constant TIME_UNIT = 60;

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
        address referrer;
        bool active;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => address) public referrers;
    mapping(address => bool) public isEffectiveUser;

    uint256 public totalStaked;
    uint256 public minEffectiveStake = 50 * 10**18;

    uint256 public lpRewardPool;
    uint256 public nftRewardPool;
    address public projectTreasury;

    event Staked(address indexed user, uint256 amount, bool isEffective, bool isAuto);
    event RewardClaimed(address indexed user, uint256 userNet, uint256 referralDistributed, uint256 periodsClaimed, bool wasEffective);
    event ReferralBonusPaid(address indexed referrer, address indexed downline, uint256 amount, uint8 level);
    event Redeemed(address indexed user, uint256 returnedAmount, uint256 burnedAmount, uint256 penaltyRate);
    event BoundReferrer(address indexed user, address indexed referrer);
    event EffectiveUserUpdated(address indexed user, bool status);

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

    // ==================== 查看自己上级 ====================
    function getReferrer(address user) public view returns (address) {
        return referrers[user];
    }

    // ==================== 查看自己 referral 链深度 ====================
    function getMyReferralDepth() public view returns (uint8 depth) {
        address current = referrers[msg.sender];
        while (current != address(0) && depth < MAX_REFERRAL_LEVELS) {
            depth++;
            current = referrers[current];
        }
        return depth;
    }

    // ==================== 查看底池信息 ====================
    function getPoolInfo() public view returns (
        uint256 totalStakedAmount,
        uint256 contractBalance,
        uint256 currentRate
    ) {
        totalStakedAmount = totalStaked;
        contractBalance = asteroToken.balanceOf(address(this));
        currentRate = getCurrentRate();
    }

    // ==================== 查看待领取收益 ====================
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

    // ==================== OWNER ====================
    function setMinEffectiveStake(uint256 _amount) external onlyOwner {
        minEffectiveStake = _amount;
    }

    function setRates(uint256 _high, uint256 _mid, uint256 _low) external onlyOwner {
        rateHigh = _high;
        rateMid = _mid;
        rateLow = _low;
    }

    function setProjectTreasury(address _addr) external onlyOwner {
        projectTreasury = _addr;
    }

    function withdrawBNB(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }

    // ==================== BIND REFERRER ====================
    function bindReferrer(address referrer) external {
        require(referrers[msg.sender] == address(0), "already bound");
        require(referrer != address(0) && referrer != msg.sender, "invalid referrer");
        referrers[msg.sender] = referrer;
        emit BoundReferrer(msg.sender, referrer);

        if (asteroToken.balanceOf(address(this)) >= 3 * 10**18) {
            asteroToken.transfer(msg.sender, 2 * 10**18);
            asteroToken.transfer(referrer, 1 * 10**18);
        }
    }

    // ==================== AUTO STAKE ====================
    function onDirectStake(address user, uint256 amount) external {
        require(msg.sender == address(asteroToken), "only token");
        require(amount > 0, "amount > 0");
        require(!stakes[user].active, "already staking, redeem first");

        bool makesEffective = amount >= minEffectiveStake;
        if (makesEffective) {
            isEffectiveUser[user] = true;
            emit EffectiveUserUpdated(user, true);
        }

        stakes[user] = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
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

        bool makesEffective = amount >= minEffectiveStake;
        if (makesEffective) {
            isEffectiveUser[msg.sender] = true;
            emit EffectiveUserUpdated(msg.sender, true);
        }

        if (referrers[msg.sender] == address(0) && referrer != address(0) && referrer != msg.sender) {
            referrers[msg.sender] = referrer;
            emit BoundReferrer(msg.sender, referrer);
            if (asteroToken.balanceOf(address(this)) >= 3 * 10**18) {
                asteroToken.transfer(msg.sender, 2 * 10**18);
                asteroToken.transfer(referrer, 1 * 10**18);
            }
        }

        stakes[msg.sender] = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
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

    // ==================== 完成绑定（由 Token 调用） ====================

function completeBind(address downline, address up) external {
    require(msg.sender == address(asteroToken), "only token can call");
    require(referrers[downline] == address(0), "already bound");
    require(downline != up, "cannot bind to self");

    referrers[downline] = up;
    emit BoundReferrer(downline, up);

    // 可选：绑定成功后从合约给 2+1 奖励（如果你还想保留）
    if (asteroToken.balanceOf(address(this)) >= 3 * 10**18) {
        asteroToken.transfer(downline, 2 * 10**18);
        asteroToken.transfer(up, 1 * 10**18);
    }
}

    receive() external payable {}
}