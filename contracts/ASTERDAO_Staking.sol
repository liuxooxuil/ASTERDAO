// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ASTERDAO Staking & Yield Contract
 * @dev Full-chain staking with:
 *      - Deposit (max 5000U USD value, one stake per address until redeem)
 *      - Referral binding (up to 16 levels, % of static yield)
 *      - Dynamic daily yield 1%-1.5% based on pool size (total staked in contract)
 *      - Activation: pay 1 ASTER + gas to activate 10-day earning period (stackable/extendable)
 *      - Claim yield (with auto referral distribution)
 *      - Exit: send 10 ASTER to contract -> get time-based % principal back, rest + fee burned to blackhole
 *      - Effective user tracking (>=50U deposit, revoked on exit)
 *      - All values adjustable by owner before renounce
 *
 * YIELD SOURCE: Funded by 5% tax "poolBack" sent to this contract address + any other inflows.
 * Referral & LP/NFT shares paid from the same pool.
 *
 * WARNING: Complex DeFi logic. NOT AUDITED. High risk of economic exploits, math errors, 
 *          reentrancy (mitigated with guard), price manipulation (use USDT pair), etc.
 *          Recommend professional audit + bug bounty before mainnet.
 *          "Auto to wallet without claim" is difficult on-chain without keepers (gas cost).
 *          Current: claim-on-demand + optional Chainlink Automation keeper.
 *          LP 10% + NFT 2% shares: TODO in this version (see comments). Can be added via sub-staking.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IASTERDAO {
    function getCurrentPrice() external view returns (uint256);
    function isWhitelisted(address) external view returns (bool);
}

contract ASTERDAOStaking {
    // For production: import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
    // contract ... is ReentrancyGuard {

    IERC20 public immutable asterToken;
    IASTERDAO public immutable asterDAO; // For price
    address public owner;
    address public projectAddress;      // For unclaimed referral shares + activation fees
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Reentrancy guard
    bool private _locked;

    // Adjustable params (owner only until renounce)
    uint256 public activationFee = 1 * 10**18;      // 1 ASTER per activation
    uint256 public exitTriggerFee = 10 * 10**18;    // 10 ASTER to exit
    uint256 public maxPerAddressUSD = 5000 * 10**18; // 5000 U
    uint256 public minEffectiveUSD = 50 * 10**18;   // 50 U for effective/referral credit
    uint256 public activationPeriodDays = 10;       // 10 days per activation

    // Referral rates in basis points (first gen 10%, second 6%, 3-5:4%, 6-16:2%)
    uint256[16] public referralRatesBP = [1000, 600, 400, 400, 400, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200];

    struct StakeInfo {
        uint256 amount;             // Staked ASTER
        uint256 stakeTimestamp;
        uint256 lastClaimTimestamp;
        address referrer;
        bool activated;
        uint256 activatedUntil;     // Earning active until this time
        uint256 depositedUSD;       // USD value at deposit (for max/effective)
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => bool) public isEffectiveUser;
    uint256 public totalStaked;     // For dynamic rate (or use balanceOf(this))

    // TODO: LP and NFT yield sharing (10% + 2% of static yields)
    // To implement properly:
    // 1. Add LP token staking (separate mapping or struct for LP positions)
    // 2. NFT staking (since only 30, use ERC721 balance or stake specific tokenIds)
    // 3. On every yield generation, allocate 10% to LP reward pool, 2% to NFT reward pool
    // 4. Users/NFT holders claim proportional share based on weight * time
    // This requires additional reward accounting (accRewardPerShare like MasterChef).
    // For MVP, send 12% of yields to projectAddress or designated LP/NFT wallets for manual/ offchain distribution.
    // Full implementation adds ~300 lines and needs careful testing.

    event Deposited(address indexed user, uint256 amount, address referrer, uint256 usdValue);
    event Activated(address indexed user, uint256 until);
    event YieldClaimed(address indexed user, uint256 amount, uint256 referralPaid);
    event Exited(address indexed user, uint256 returned, uint256 burned, uint256 exitFeeBurned);
    event ReferrerBound(address indexed user, address indexed referrer);
    event OwnershipRenounced(address indexed previousOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _asterToken, address _asterDAOContract, address _projectAddress) {
        asterToken = IERC20(_asterToken);
        asterDAO = IASTERDAO(_asterDAOContract);
        owner = msg.sender;
        projectAddress = _projectAddress;
    }

    // ============ Dynamic Daily Rate (auto based on pool size) ============
    function getDynamicDailyRateBP() public view returns (uint256) {
        uint256 poolSize = asterToken.balanceOf(address(this)); // Real pool including all inflows
        if (poolSize < 20_000_000 * 10**18) return 0;           // <20M: no yield
        if (poolSize < 50_000_000 * 10**18) return 100;         // 1.0%
        if (poolSize < 100_000_000 * 10**18) return 120;        // 1.2%
        return 150;                                             // 1.5%
    }

    // ============ Deposit (no re-stake until exit, max 5000U, bind referrer) ============
    function deposit(uint256 _amount, address _referrer) external nonReentrant {
        require(_amount > 0, "Amount must > 0");
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount == 0, "Already staked - redeem first (single address rule)");

        uint256 price = asterDAO.getCurrentPrice();
        require(price > 0, "Price feed unavailable - set USDT pair in token first");

        uint256 usdValue = (_amount * price) / 10**18;
        require(usdValue <= maxPerAddressUSD, "Exceeds single address max 5000U");

        // Transfer tokens to this contract (the "底池")
        require(asterToken.transferFrom(msg.sender, address(this), _amount), "TransferFrom failed");

        s.amount = _amount;
        s.stakeTimestamp = block.timestamp;
        s.lastClaimTimestamp = block.timestamp;
        s.activated = false;
        s.activatedUntil = 0;
        s.depositedUSD = usdValue;
        totalStaked += _amount;

        // Bind referrer once (no order, doesn't affect own yield)
        if (_referrer != address(0) && _referrer != msg.sender && s.referrer == address(0)) {
            s.referrer = _referrer;
            emit ReferrerBound(msg.sender, _referrer);
        }

        // Effective user if >=50U (revoked on exit)
        if (usdValue >= minEffectiveUSD) {
            isEffectiveUser[msg.sender] = true;
        }

        emit Deposited(msg.sender, _amount, s.referrer, usdValue);
    }

    // ============ Activate earning (pay 1 ASTER fee, extend 10 days, stackable) ============
    function activate() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount > 0, "No active stake");
        require(s.activatedUntil < block.timestamp + 365 days, "Already long activated"); // safety

        // Pay activation fee (1 ASTER) - sent to project
        require(asterToken.transferFrom(msg.sender, address(this), activationFee), "Need to pay 1 ASTER activation fee");
        // Send fee to project (or burn/marketing)
        asterToken.transfer(projectAddress, activationFee);

        // Extend/activate earning period (stackable by calling multiple times)
        uint256 newUntil = block.timestamp + (activationPeriodDays * 1 days);
        if (s.activatedUntil > block.timestamp) {
            newUntil = s.activatedUntil + (activationPeriodDays * 1 days); // stack
        }
        s.activated = true;
        s.activatedUntil = newUntil;

        emit Activated(msg.sender, newUntil);
    }

    // ============ Claim yield (auto calculates dynamic rate, distributes referrals) ============
    function claimYield() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount > 0, "No stake");
        require(s.activated && block.timestamp <= s.activatedUntil, "Not activated or period expired - activate first");

        uint256 timePassed = block.timestamp - s.lastClaimTimestamp;
        if (timePassed == 0) return;

        uint256 dailyRateBP = getDynamicDailyRateBP();
        if (dailyRateBP == 0) return; // No yield below 20M pool

        // pending = amount * rate * seconds / (10000 * 86400)
        uint256 pending = (s.amount * dailyRateBP * timePassed) / (10000 * 86400);

        if (pending == 0) return;

        s.lastClaimTimestamp = block.timestamp;

        // Distribute referral commissions (extra from pool, user gets full pending)
        uint256 referralPaid = _distributeReferral(msg.sender, pending);

        // Pay user his full static yield
        require(asterToken.transfer(msg.sender, pending), "Yield transfer failed");

        emit YieldClaimed(msg.sender, pending, referralPaid);
    }

    // View pending yield (for frontend)
    function getPendingYield(address user) public view returns (uint256) {
        StakeInfo storage s = stakes[user];
        if (s.amount == 0 || !s.activated || block.timestamp > s.activatedUntil) return 0;

        uint256 timePassed = block.timestamp - s.lastClaimTimestamp;
        if (timePassed == 0) return 0;

        uint256 dailyRateBP = getDynamicDailyRateBP();
        if (dailyRateBP == 0) return 0;

        return (s.amount * dailyRateBP * timePassed) / (10000 * 86400);
    }

    // Internal referral distribution (traverse up to 16 levels)
    function _distributeReferral(address user, uint256 baseYield) internal returns (uint256 totalReferralPaid) {
        address current = stakes[user].referrer;
        uint256 remaining = baseYield; // For unclaimed levels -> project

        for (uint256 i = 0; i < 16; i++) {
            if (current == address(0)) break;

            uint256 share = (baseYield * referralRatesBP[i]) / 10000;
            if (share > 0 && asterToken.balanceOf(address(this)) >= share) {
                asterToken.transfer(current, share);
                totalReferralPaid += share;
                remaining -= share;
            }
            current = stakes[current].referrer;
        }

        // Remaining (levels without referrer or after 16) to project
        if (remaining > 0 && asterToken.balanceOf(address(this)) >= remaining) {
            asterToken.transfer(projectAddress, remaining);
        }
        return totalReferralPaid;
    }

    // ============ Exit / Redeem with time-based penalty + 10 ASTER trigger ============
    function exitStake() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount > 0, "No active stake");

        // User must send 10 ASTER trigger fee to this contract first (or approve + transferFrom)
        require(asterToken.transferFrom(msg.sender, address(this), exitTriggerFee), "Send 10 ASTER exit trigger fee");

        // Burn the 10 ASTER trigger fee + time penalty portion
        asterToken.transfer(DEAD, exitTriggerFee);

        uint256 timeStaked = block.timestamp - s.stakeTimestamp;

        uint256 returnPct = 70;
        if (timeStaked > 30 days) returnPct = 100;
        else if (timeStaked > 20 days) returnPct = 90;
        else if (timeStaked > 10 days) returnPct = 80;

        uint256 toReturn = (s.amount * returnPct) / 100;
        uint256 toBurn = s.amount - toReturn;

        totalStaked -= s.amount;

        // Return principal % to user
        if (toReturn > 0) {
            asterToken.transfer(msg.sender, toReturn);
        }

        // Burn the penalty portion to blackhole
        if (toBurn > 0) {
            asterToken.transfer(DEAD, toBurn);
        }

        // Cleanup
        uint256 oldAmount = s.amount;
        s.amount = 0;
        s.activated = false;
        s.referrer = address(0);
        isEffectiveUser[msg.sender] = false; // Revoke effective status if withdrew

        emit Exited(msg.sender, toReturn, toBurn, exitTriggerFee);
    }

    // ============ Owner functions (adjustable before renounce) ============
    function setProjectAddress(address _addr) external onlyOwner {
        projectAddress = _addr;
    }

    function setActivationFee(uint256 _fee) external onlyOwner {
        activationFee = _fee;
    }

    function setExitTriggerFee(uint256 _fee) external onlyOwner {
        exitTriggerFee = _fee;
    }

    function setReferralRate(uint256 level, uint256 rateBP) external onlyOwner {
        require(level < 16, "Level 0-15");
        referralRatesBP[level] = rateBP;
    }

    function setMaxPerAddressUSD(uint256 _maxUSD) external onlyOwner {
        maxPerAddressUSD = _maxUSD;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipRenounced(owner);
        owner = address(0);
    }

    // Emergency: owner can recover stuck tokens before renounce (safety)
    function emergencyRecover(address token, uint256 amount) external onlyOwner {
        if (token == address(asterToken)) {
            // Careful with staked funds
            require(amount <= asterToken.balanceOf(address(this)) - totalStaked, "Cannot touch staked principal");
        }
        IERC20(token).transfer(owner, amount);
    }

    // View total pool size (for UI/rate)
    function getPoolSize() external view returns (uint256) {
        return asterToken.balanceOf(address(this));
    }
}