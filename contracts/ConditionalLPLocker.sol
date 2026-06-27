// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Conditional LP Locker for ASTERDAO
 * @dev 处理“指定地址的LP在100天内撤池子，只有U没有币，币自动销毁”的需求
 *
 * 使用方式：
 * 1. 项目方把指定 LP token 转入此合约（或用此合约添加流动性）
 * 2. 设置 lockDuration = 100 days
 * 3. 只有 owner（或指定地址）能调用 removeLiquidity
 * 4. 如果在 lockDuration 内移除 → ASTER 部分自动销毁到 DEAD，只返还配对代币（U/BNB）
 * 5. 超过 lockDuration 后正常移除，可同时拿到 U 和 ASTER
 *
 * 注意：此合约需要与 PancakeRouter 交互，实际 removeLiquidity 需要授权和路由地址。
 * 生产环境建议使用更完善的 Timelock + Conditional 逻辑。
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPancakeRouter {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

contract ConditionalLPLocker {
    address public owner;
    address public asterToken;
    address public pairedToken;      // USDT or WBNB
    address public lpToken;          // Pancake LP token address
    address public router;           // PancakeRouter address
    uint256 public lockDuration = 100 days;
    uint256 public lockedAt;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event LiquidityRemovedEarly(address indexed caller, uint256 lpBurned, uint256 pairedReturned, uint256 asterBurned);
    event LiquidityRemovedNormally(address indexed caller, uint256 amountA, uint256 amountB);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _asterToken,
        address _pairedToken,
        address _lpToken,
        address _router
    ) {
        owner = msg.sender;
        asterToken = _asterToken;
        pairedToken = _pairedToken;
        lpToken = _lpToken;
        router = _router;
        lockedAt = block.timestamp;
    }

    // 项目方可把 LP token 转入此合约
    function depositLP(uint256 amount) external onlyOwner {
        IERC20(lpToken).transferFrom(msg.sender, address(this), amount);
    }

    // 移除流动性（带条件判断）
    function removeLiquidity(uint256 liquidity, uint256 amountAMin, uint256 amountBMin) external onlyOwner {
        require(liquidity > 0, "liquidity > 0");
        require(IERC20(lpToken).balanceOf(address(this)) >= liquidity, "Insufficient LP");

        uint256 timeLocked = block.timestamp - lockedAt;
        bool isEarly = timeLocked < lockDuration;

        // 授权 Router
        IERC20(lpToken).approve(router, liquidity);

        (uint256 amountA, uint256 amountB) = IPancakeRouter(router).removeLiquidity(
            asterToken,
            pairedToken,
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + 300
        );

        if (isEarly) {
            // 100天内：ASTER 部分销毁，只返还配对代币
            uint256 asterAmount = amountA; // 假设 amountA 是 ASTER
            if (asterAmount > 0) {
                IERC20(asterToken).transfer(DEAD, asterAmount);
            }
            // 把配对代币（U）转给 owner
            if (amountB > 0) {
                IERC20(pairedToken).transfer(owner, amountB);
            }
            emit LiquidityRemovedEarly(msg.sender, liquidity, amountB, asterAmount);
        } else {
            // 正常情况：把 ASTER 和 配对代币都转给 owner
            if (amountA > 0) IERC20(asterToken).transfer(owner, amountA);
            if (amountB > 0) IERC20(pairedToken).transfer(owner, amountB);
            emit LiquidityRemovedNormally(msg.sender, amountA, amountB);
        }
    }

    function setLockDuration(uint256 _days) external onlyOwner {
        lockDuration = _days * 1 days;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }
}