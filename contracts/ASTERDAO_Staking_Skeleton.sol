// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

/**
 * @title ASTERDAO Staking - Final Logic Version (Following your exact requirements)
 *
 * Core Logic Implemented:
 * - User stakes ASTERDAO + BNB into this contract
 * - Daily reward 1%~1.5% based on totalStaked pool
 * - When claiming: Calculate gross reward → Deduct total referral % first → User gets net
 * - Deducted referral portion is distributed to the 16-level chain
 * - If no referrer at some level, remaining goes to projectTreasury
 * - Only effective users (can be extended with oracle) participate in referral
 * - 10% of static reward → LP pool
 * - 2% of static reward → NFT pool
 * - Early redeem with time penalty + all penalty to blackhole
 */

contract ASTERDAOStaking is Ownable, ReentrancyGuard {
    IERC20 public immutable asteroToken;
    address public constant BLACKHOLE = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant MAX_REFERRAL_LEVELS = 16;
    uint256 public constant STAKE_PERIOD_DAYS = 10;

    // Dynamic daily rates (in basis points)
    uint256 public rateHigh = 150;   // 1.5%
    uint256 public rateMid = 120;    // 1.2%
    uint256 public rateLow = 100;    // 1.0%
    uint256 public rateZeroBelow = 20_000_000 * 10**18;

    // Referral rates (basis points)
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
    uint256 public totalStaked;

    uint256 public lpRewardPool;
    uint256 public nftRewardPool;

    address public projectTreasury;

    // Events
    event Staked(address indexed user, uint256 amount, address referrer);
    event RewardClaimed(address indexed user, uint256 userNet, uint256 referralDistributed, uint256 daysClaimed);
    event ReferralBonusPaid(address indexed referrer, address indexed downline, uint256 amount, uint8 level);
    event Redeemed(address indexed user, uint256 returnedAmount, uint256 burnedAmount, uint256 penaltyRate);
    event BoundReferrer(address indexed user, address indexed referrer);

    constructor(address _asteroToken, address _projectTreasury) Ownable() {
        require(_asteroToken != address(0), "token zero");
        asteroToken = IERC20(_asteroToken);
        projectTreasury = _projectTreasury;
    }

    // ==================== DYNAMIC RATE ====================
    function getCurrentRate() public view returns (uint256) {
        if (totalStaked >= 100_000_000 * 10**18) return rateHigh;
        if (totalStaked >= 50_000_000 * 10**18) return rateMid;
        if (totalStaked >= 20_000_000 * 10**18) return rateLow;
        return 0;
    }

    // ==================== STAKE ====================
    function stake(uint256 amount, address referrer) external payable nonReentrant {
        require(amount > 0, "amount > 0");
        require(!stakes[msg.sender].active, "already staking, please redeem first");
        require(msg.value > 0, "please send some BNB");

        require(asteroToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");

        // Auto bind referrer if not bound
        if (referrers[msg.sender] == address(0) && referrer != address(0) && referrer != msg.sender) {
            referrers[msg.sender] = referrer;
            emit BoundReferrer(msg.sender, referrer);

            // Dynamic reward: 2 tokens to new user, 1 back to referrer
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
        emit Staked(msg.sender, amount, referrers[msg.sender]);
    }

    // ==================== CLAIM DAILY REWARD (Following your logic) ====================
    function claimDailyReward() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");

        uint256 rate = getCurrentRate();
        if (rate == 0) {
            userStake.lastClaimTime = block.timestamp;
            return;
        }

        uint256 daysPassed = (block.timestamp - userStake.lastClaimTime) / 86400;
        if (daysPassed == 0) return;
        daysPassed = daysPassed > STAKE_PERIOD_DAYS ? STAKE_PERIOD_DAYS : daysPassed;

        // 1. Calculate gross reward
        uint256 grossReward = (userStake.amount * rate * daysPassed) / 10000;

        // 2. Calculate total referral commission rate (sum of all 16 levels)
        uint256 totalReferralRate = 0;
        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            totalReferralRate += referralRates[i];
        }

        // 3. Deduct referral portion first
        uint256 referralDeducted = (grossReward * totalReferralRate) / 10000;

        // 4. User net reward after referral deduction + LP/NFT split
        uint256 afterReferral = grossReward - referralDeducted;

        uint256 lpShare = afterReferral * 10 / 100;
        uint256 nftShare = afterReferral * 2 / 100;
        uint256 userNet = afterReferral - lpShare - nftShare;

        lpRewardPool += lpShare;
        nftRewardPool += nftShare;

        // 5. Distribute referral portion to the chain
        uint256 actuallyDistributed = _distributeReferralRewards(msg.sender, referralDeducted, userStake.referrer);

        // 6. Send net reward to user
        if (userNet > 0) {
            asteroToken.transfer(msg.sender, userNet);
        }

        userStake.lastClaimTime = block.timestamp;

        emit RewardClaimed(msg.sender, userNet, actuallyDistributed, daysPassed);
    }

    // ==================== Distribute Referral Rewards (16 levels) ====================
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

        // Remaining goes to project treasury
        if (remaining > 0 && projectTreasury != address(0)) {
            asteroToken.transfer(projectTreasury, remaining);
            distributed += remaining;
        }
    }

    // ==================== REDEEM ====================
    function redeem() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.active, "no active stake");

        // Trigger fee
        uint256 triggerFee = 10 * 10**18;
        if (asteroToken.balanceOf(msg.sender) >= triggerFee) {
            asteroToken.transferFrom(msg.sender, address(this), triggerFee);
            asteroToken.transfer(BLACKHOLE, triggerFee);
        }

        uint256 daysStaked = (block.timestamp - userStake.startTime) / 86400;

        uint256 returnRate;
        if (daysStaked <= 10) returnRate = 70;
        else if (daysStaked <= 20) returnRate = 80;
        else if (daysStaked <= 30) returnRate = 90;
        else returnRate = 100;

        uint256 principal = userStake.amount;
        uint256 returnAmount = (principal * returnRate) / 100;
        uint256 burnAmount = principal - returnAmount;

        totalStaked -= principal;
        userStake.active = false;
        userStake.amount = 0;

        if (returnAmount > 0) asteroToken.transfer(msg.sender, returnAmount);
        if (burnAmount > 0) asteroToken.transfer(BLACKHOLE, burnAmount);

        emit Redeemed(msg.sender, returnAmount, burnAmount, returnRate);
    }

    // ==================== OWNER ====================
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

    receive() external payable {}
}