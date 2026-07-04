// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

interface IUniswapPair {
    function sync() external;
}

interface IUniswapV2Factory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IUniswapV2Router {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
    external
    view
    returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

}

contract TokenDistributor {
    mapping(address => bool) private _feeWhiteList;
    constructor () {
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[tx.origin] = true;
    }

    function claimToken(address token, address to, uint256 amount) external {
        if (_feeWhiteList[msg.sender]) {
            IERC20(token).transfer(to, amount);
        }
    }

    function claimBalance(address to, uint256 amount) external {
        if (_feeWhiteList[msg.sender]) {
            _safeTransferETH(to, amount);
        }
    }

    function _safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        if (success) {}
    }

    receive() external payable {}
}

contract LDCToken is IERC20,IERC20Errors,Ownable {
    mapping(address account => uint256) private _balances;
    mapping(address account => mapping(address spender => uint256)) private _allowances;
    uint256 private _totalSupply;
    uint256 private _decimals = 18;
    string private _name;
    string private _symbol;

    address public immutable usdt = 0x55d398326f99059fF775485246999027B3197955;
    
    TokenDistributor public immutable _autoMarketDistributor;
    TokenDistributor public immutable _floorPriceDistributor;
    TokenDistributor public immutable _dividendDistributor;
    IUniswapV2Router public immutable _uniswapV2Router;
    address public _uniswapPair;
    address[] public floorPriceBL;
    mapping (address => User) public users;
    address[] public dividendUsers;
    address public fund;
    mapping (address => bool) public bots;
    mapping (address => bool) public BL;
    
    uint256 public dividendUTotal;
    uint256 public dividendIndex;
    uint256 public dividendRewards;
    address public pool = address(0);

    //fee
    uint256 public buyTotal;
    uint256 public feeTotal;
    uint256 buyFee = 200; //div 10000
    uint256 sellFee = 300; 
    uint256 profitFee = 1000;
    uint256 DPR = 10000e18; //dividend performance requirements
    uint256 DBR = 1000e18; //dividend burn requirements
    uint256 public toggleAmount = 1 * 10 ** 18;

    //mining
    uint256 public miningPoolBalance;
    uint256 rewardPerBlock = uint256(uint256(37000 * 10 ** 18) / 28800);
    uint256 private constant ACC_REWARD_PRECISION = 1e12;
    uint256 public accRewardPerShare;
    uint256 public lastRewardBlock;
    uint256 public burnTotal;
    
    bool public startTrade = false;
    bool public startMining = false;

    struct User {
        address upline;
        address[] downlines;
        uint256 performance;
        uint256 received;
        uint256 earned;
        uint256 burnTotal;
        uint256 miningTotal;
        uint256 burnUvalue;
        int256 rewardDebt;
    }
    event runBot(bool);

    constructor(address recipient, address _initialOwner, address _fund, address _bot) Ownable(_initialOwner) {
        _name = "LDC";
        _symbol = "LDC";
        _uniswapV2Router = IUniswapV2Router(
            0x10ED43C718714eb63d5aA57B78B54704E256024E //pancake
        );

        _uniswapPair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(
            address(this),
            usdt
        );
        _addFPBL(address(0xdead));
        _addFPBL(address(0));
        _addFPBL(address(_uniswapPair));
        _addFPBL(address(_fund));

        _approve(address(this), address(_uniswapV2Router), ~uint256(0));
        fund = _fund;
        bots[_bot] = true;

        _autoMarketDistributor = new TokenDistributor();
        _floorPriceDistributor = new TokenDistributor();
        _dividendDistributor = new TokenDistributor();

        _totalSupply = 5000_0000 * 10 ** _decimals;
        miningPoolBalance = 3700_0000 * 10 ** _decimals;
        _balances[recipient] =  1300_0000 * 10 ** _decimals;
        _balances[pool] =  3700_0000 * 10 ** _decimals;
        
        emit Transfer(address(0), recipient,  _totalSupply);
    }

    function name() public view returns (string memory) {
        return _name;
    }
    
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    
    function decimals() public view returns (uint256) {
        return _decimals;
    }
    
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account] + earned(account);
    }
    
    function transfer(address to, uint256 value) public returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }
    
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 value) public returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }
    
    function _basicTransfer(address from,address to, uint256 value) internal {
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) {
            revert ERC20InsufficientBalance(from, fromBalance, value);
        }
        unchecked {
            _balances[from] = fromBalance - value;
        }

        unchecked {
            _balances[to] += value;
        }
        if (from != address(0)) {
            emit Transfer(from, to, value);
        }
    }
    
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }
    
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }
    
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
    
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    function getUser(address _user) public view returns(User memory) {
        return users[_user];
    }

    function _update(address from,address to,uint256 value) internal  {
        require(!BL[from] && !BL[to],"BL");
        if (from == address(0)) {
            _update(from, to, value);
            return;
        }
        if (!isContract(from)) {
            getReward(from);
        }

        if (!isContract(from) && to == address(this)) {
            uint256 _uAmount = value * getFloorPrice() / 1e18;
            _basicTransfer(from, address(0xdead), value);
            _floorPriceDistributor.claimToken(usdt, from, _uAmount);
            return;
        }

        if (!isContract(from) && !isContract(to) && to != address(0) && to != address(0xdead) && value == 1e18) {
            if (!inArray(to, users[from].downlines) && !inArray(from, users[to].downlines)) {
                if (users[to].upline == address(0)) {
                    users[from].downlines.push(to);
                }
            }

            if (inArray(from, users[to].downlines) && users[from].upline == address(0)) {
                users[from].upline = to;
            }
            _basicTransfer(from, to, value);
            return;
        }
        
        if(to == address(0xdead) && !isContract(from)) {
            takeDead(from, value);
            _basicTransfer(from, to, value);
            return;
        }

        if (from == address(this) || to == address(this) || from == owner() || to == owner()) {
            _basicTransfer(from, to, value);
            return;
        }

        if (_uniswapPair == from || _uniswapPair == to) {
            require(startTrade, "not open");
            if (_uniswapPair == from) {
                if (getSellUsdtAmount(value) >= 200e18) {
                    emit runBot(true);
                }
                uint256 fee = value * buyFee / 10000;
                value -= fee;
                _basicTransfer(from, address(this), fee);
                feeTotal += fee;
                buyTotal += value * 15 / 100;
                updateConstAmount(to, value);
            }
            
            if (_uniswapPair == to) {
                uint256 fee = value * sellFee / 10000;
                value -= fee;
                _basicTransfer(from, address(this), fee);
                feeTotal += fee;

                uint256 profitAmount = getProfitAmount(from, value);
                if (profitAmount > 0) {
                    if (profitFee > 0) {
                        uint256 pFee = profitAmount * profitFee / 10000;
                        value -=  pFee;
                        _basicTransfer(from, address(this), pFee);
                        profitToUSDT(pFee);
                    }
                }

                _basicTransfer(_uniswapPair, address(0xdead), value * 7 / 100);
                _basicTransfer(_uniswapPair, fund, value * 3 / 100);
                IUniswapPair(_uniswapPair).sync();
            }
        }

        if (_uniswapPair != from) {
            swapFeeToUSDT(); 
            buyAfter();
        }

        _basicTransfer(from, to, value);
    }

    function dividendPayout() public {
        if(bots[_msgSender()]) {
            address[] memory _dividendUsers = dividendUsers;
            uint256 _total;
            for(uint256 i; i < _dividendUsers.length; i++) {
                if (getOutAmount(users[_dividendUsers[i]].performance) > users[_dividendUsers[i]].received) {
                    _total += users[_dividendUsers[i]].performance;
                }
            }

            uint256 _uBalance = IERC20(usdt).balanceOf(address(_dividendDistributor));
            uint256 _rewards = _uBalance * 20 / 100;
            uint256 _reward;
            
            if (_total == 0 || _rewards == 0) {
                return;
            }

            for(uint256 i; i < _dividendUsers.length; i++) {
                _reward = _rewards * users[_dividendUsers[i]].performance / _total;

                if (getOutAmount(users[_dividendUsers[i]].performance) < users[_dividendUsers[i]].received + _reward ) {
                    _reward = getOutAmount(users[_dividendUsers[i]].performance) - users[_dividendUsers[i]].received;
                }
                if (_reward > 0) {
                    users[_dividendUsers[i]].received += _reward;
                    _dividendDistributor.claimToken(usdt, _dividendUsers[i], _reward);
                }
            }
        } else {
            return;
        }
    }

    function dividendPayout2() public {
        if(bots[_msgSender()]) {
            address[] memory _dividendUsers = dividendUsers;
            uint256 _total;
            for(uint256 i; i < _dividendUsers.length; i++) {
                if (getOutAmount(users[_dividendUsers[i]].performance) > users[_dividendUsers[i]].received) {
                    _total += users[_dividendUsers[i]].performance;
                }
            }

            uint256 _dividendIndex = dividendIndex;
            uint256 _rewards;
            if (_dividendIndex == 0) {
                uint256 _uBalance = IERC20(usdt).balanceOf(address(_dividendDistributor));
                _rewards = _uBalance * 20 / 100;
                dividendRewards = _rewards;
            } else {
                _rewards = dividendRewards;
            }
            uint256 _reward;

            if (_total == 0 || _rewards == 0) {
                return;
            }

            uint256 iterations;
            while(_dividendUsers.length > iterations && iterations < 100) {
                _dividendIndex = dividendIndex;
                if (_dividendIndex >= _dividendUsers.length) {
                    dividendIndex = 0;
                    break;
                }
                _reward = _rewards * users[_dividendUsers[_dividendIndex]].performance / _total;

                if (getOutAmount(users[_dividendUsers[_dividendIndex]].performance) < users[_dividendUsers[_dividendIndex]].received + _reward ) {
                    _reward = getOutAmount(users[_dividendUsers[_dividendIndex]].performance) - users[_dividendUsers[_dividendIndex]].received;
                }
                if (_reward > 0) {
                    users[_dividendUsers[_dividendIndex]].received += _reward;
                    _dividendDistributor.claimToken(usdt, _dividendUsers[_dividendIndex], _reward);
                }
                
                dividendIndex++;
                iterations++;
            }
        } else {
            return;
        }
    }

    function autoMarket() public {
        if(bots[_msgSender()]) {
            uint256 _b = IERC20(usdt).balanceOf(address(_autoMarketDistributor));
            if (_b >= toggleAmount) {
                uint256 _uValue = _b * 3 / 100;
                _autoMarketDistributor.claimToken(usdt, _uniswapPair, _uValue);
                IUniswapPair(_uniswapPair).sync();
            }
        } else {
            
        }
    }
    
    function addFPBL(address _user) public onlyOwner {
        _addFPBL(_user);
    }

    function setTrade() public onlyOwner {
        if (!startTrade) {
            startTrade = true;
        }
    }

    function setMining() public onlyOwner {
        if (!startMining) {
            startMining = true;
            lastRewardBlock = block.number;
        }
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function setToggleAmount(uint256 value) public onlyOwner {
        toggleAmount = value;
    }

    function _addFPBL(address _user) internal {
        if (!inArray(_user, floorPriceBL)) {
            floorPriceBL.push(_user);
        }
    }

    function inArray(address addr,address[] memory arr) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == addr) {
                return true;
            }
        }
        return false;
    }

    mapping(address => uint256) internal userCostAmount;
    function updateConstAmount(address account, uint256 amount) public {
        uint256 currentAmount = getSellUsdtAmount(amount);
        userCostAmount[account] = userCostAmount[account] + currentAmount;
    }
    
    function getSellUsdtAmount(uint256 amount) public view returns (uint256){
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdt;
        uint256[] memory amounts = _uniswapV2Router.getAmountsOut(amount, path);
        return amounts[1];
    }

    function getdividendUsersLength() public view returns (uint256) {
        return dividendUsers.length;
    }
    
    // usdt -> token
    function getBuyTokenAmount(uint256 amount) public view returns (uint256){
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = address(this);
        uint256[] memory amounts = _uniswapV2Router.getAmountsOut(amount, path);
        return amounts[1];
    }
    
    function getProfitAmount(address account, uint256 amount) internal returns (uint256){
        uint256 constAmount = userCostAmount[account];
        uint256 currentAmount = getSellUsdtAmount(amount);
        if (constAmount > currentAmount) {
            userCostAmount[account] = userCostAmount[account] - currentAmount;
            return 0;
        } else if (constAmount > 0 && currentAmount > constAmount) {
            uint256 profitAmount = getBuyTokenAmount(currentAmount - constAmount);
            userCostAmount[account] = 0;
            return profitAmount;
        } else {
            userCostAmount[account] = 0;
            return amount;
        }
    }

    function getFloorPrice() public view returns(uint256) {
        address[] memory _fpbl = floorPriceBL;
        uint256 _fpblTotal = dividendUTotal;
        for(uint256 i; i < _fpbl.length; i++) {
            _fpblTotal += _balances[_fpbl[i]];
        }
        return IERC20(usdt).balanceOf(address(_floorPriceDistributor)) * 1e18 / (totalSupply() - _fpblTotal);
    }

    function buyAfter() public {
        if (buyTotal < toggleAmount) {
            return;
        }
        if (balanceOf(_uniswapPair) <= buyTotal) {
            return;
        }
        _basicTransfer(_uniswapPair, address(this), buyTotal);
        IUniswapPair(_uniswapPair).sync();
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdt;
        // swap token to usdt
        _uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            buyTotal,
            0,
            path,
            address(_floorPriceDistributor),
            block.timestamp
        );
        
        buyTotal = 0;
    }

    function profitToUSDT(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdt;
        // swap token to usdt
        _uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(_autoMarketDistributor),
            block.timestamp
        );
    }
    
    function swapFeeToUSDT() public {
        if (feeTotal < toggleAmount) { 
            return ;
        }
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdt;
        
        // swap token to usdt
        _uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            feeTotal,
            0,
            path,
            address(_dividendDistributor),
            block.timestamp
        );
        feeTotal = 0;
    }

    function getOutAmount(uint256 amount) internal pure returns (uint256) {
        return amount * 3 / 2;
    }
    
    //get mining 
    function getReward(address account) internal {
        _updateReward();
        uint256 _reward = earned(account);
        if (_reward == 0) {
            return;
        }
        User storage _user = users[account];

        int256 _accumulatedRewards = int256((_user.miningTotal * accRewardPerShare) / ACC_REWARD_PRECISION);
        _user.rewardDebt = _accumulatedRewards;
        
        if (_reward >= (getOutAmount(_user.burnTotal) - _user.earned)) {
            _reward = getOutAmount(_user.burnTotal) - _user.earned;
            burnTotal -= _user.miningTotal;
            _user.miningTotal = 0;
            _user.rewardDebt = 0;
        }

        if (_reward > miningPoolBalance) {
            _reward = miningPoolBalance;
        }
        if (miningPoolBalance > 0) {
            miningPoolBalance -= _reward;
            _user.earned += _reward;
            _basicTransfer(pool, account, _reward);
        }
    }
    
    function earned(address account) public view returns (uint256) {
        User memory _user = users[account];
        uint256 _outAmount = getOutAmount(_user.burnTotal);
        if (lastRewardBlock == 0 || _user.earned >= _outAmount || !startMining || burnTotal == 0 || miningPoolBalance == 0) {
            return 0;
        }

        uint256 _accRewardPerShare = accRewardPerShare;
        
        if (block.number > lastRewardBlock && burnTotal != 0) {
            uint256 _timePast = block.number - lastRewardBlock;
            uint256 _rewards = _timePast * rewardPerBlock;
            _accRewardPerShare = _accRewardPerShare + ((_rewards * ACC_REWARD_PRECISION) / burnTotal);
        }

        uint256 _reward = uint256(_user.miningTotal * _accRewardPerShare / ACC_REWARD_PRECISION) - uint256(_user.rewardDebt);
        
        if (_reward > (_outAmount - _user.earned)) {
            return _outAmount - _user.earned;
        }

        if (_reward > miningPoolBalance) {
            return miningPoolBalance;
        }
        return _reward;
    }

    function takeDead(address _user, uint256 value) internal {
        _updateReward();
        User storage user = users[_user];
        uint256 uValue = getSellUsdtAmount(value);
        address _upline = user.upline;
        User storage uplineUser = users[_upline];
        
        user.miningTotal += value;
        user.burnTotal += value;
        user.burnUvalue += uValue;
        user.rewardDebt = user.rewardDebt + int256(value * accRewardPerShare) / int256(ACC_REWARD_PRECISION);
        burnTotal += value;
        
        if (_upline != address(0)) {
            uplineUser.performance += uValue;
            if (uplineUser.burnUvalue >= DBR && uplineUser.performance >= DPR) {
                if (!inArray(_upline, dividendUsers)) {
                    dividendUsers.push(_upline);
                }
            }
        }

        if (user.burnUvalue >= DBR && user.performance >= DPR) {
            if (!inArray(_user, dividendUsers)) {
                dividendUsers.push(_user);
            }
        }
    }
    
    function _updateReward() internal{
        if (block.number > lastRewardBlock) {
            if (burnTotal > 0) {
                uint256 _timePast = block.number - lastRewardBlock;
                uint256 _rewards = _timePast * rewardPerBlock;
                accRewardPerShare = accRewardPerShare + (_rewards * ACC_REWARD_PRECISION) / burnTotal;
            }
            lastRewardBlock = block.number;
        }
    }

    function setBL(address[] memory accounts, bool b) public onlyOwner {
        for (uint256 i; i < accounts.length; i++) {
            BL[accounts[i]] = b;
        }
    }
}