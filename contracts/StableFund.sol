// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  StableFund - refined
  - Optimized storage and events
  - Immutable references for gas savings
  - More informative events (with balances after action)
  - Stricter checks for safety (avoid fee > deposit, minDeposit = 0 edge cases)
  - Added user enumeration counters
  - Added helper views: userInfo(), contractHealth()
*/

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StableFund is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    /* ========== ERRORS ========== */
    error ZeroAddress();
    error AmountZero();
    error AmountBelowMinimum();
    error InsufficientBalance();
    error ArrayLengthMismatch();
    error FeeTooHigh();
    error InvalidPercent();
    error NotAuthorized();
    error TreasuryNotSet();
    error AmountExceedsCollectedFees();
    error NoContractBalance();
    error RescueNotAllowed();

    /* ========== STATE ========== */
    IERC20 public immutable stableToken;

    address public treasury;                 
    uint256 public totalDeposits;            
    uint256 public collectedFees;            
    uint256 public minimumDeposit;           
    uint256 public withdrawalFee;            

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;

    mapping(address => bool) private _isUser;
    uint256 public totalUsers;

    /* ========== CONSTANTS ========== */
    uint256 public constant MAX_WITHDRAWAL_FEE_BP = 1_000; // 10%

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 requested, uint256 received, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 gross, uint256 fee, uint256 net, uint256 newBalance);
    event WithdrawAll(address indexed user, uint256 gross, uint256 fee, uint256 net);

    event Rebalanced(uint256 totalDeposits, uint256 contractBalance);
    event AdminAuthorized(address indexed user, bool authorized);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesClaimed(address indexed treasury, uint256 amount);
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    /* ========== CONSTRUCTOR ========== */
    constructor(address tokenAddress, uint256 _minimumDeposit, uint256 _withdrawalFee) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_withdrawalFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();

        stableToken = IERC20(tokenAddress);
        minimumDeposit = _minimumDeposit;
        withdrawalFee = _withdrawalFee;

        authorizedUsers[msg.sender] = true; // deployer is auto-authorized
    }

    /* ========== MODIFIERS ========== */
    modifier onlyAuthorizedOrOwner() {
        if (msg.sender != owner() && !authorizedUsers[msg.sender]) revert NotAuthorized();
        _;
    }

    /* ========== USER ACTIONS ========== */
    function deposit(uint256 requestedAmount) external whenNotPaused nonReentrant {
        if (requestedAmount == 0) revert AmountZero();

        uint256 before = stableToken.balanceOf(address(this));
        stableToken.safeTransferFrom(msg.sender, address(this), requestedAmount);
        uint256 received = stableToken.balanceOf(address(this)) - before;

        if (received < minimumDeposit) revert AmountBelowMinimum();

        _addBalance(msg.sender, received);

        emit Deposited(msg.sender, requestedAmount, received, balances[msg.sender]);
    }

    function withdraw(uint256 amount) public whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        uint256 bal = balances[msg.sender];
        if (bal < amount) revert InsufficientBalance();

        uint256 fee = _calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        balances[msg.sender] = bal - amount;
        totalDeposits -= amount;
        if (fee > 0) collectedFees += fee;

        uint256 contractBal = stableToken.balanceOf(address(this));
        if (contractBal < net + collectedFees) revert NoContractBalance();

        stableToken.safeTransfer(msg.sender, net);

        emit Withdrawn(msg.sender, amount, fee, net, balances[msg.sender]);
    }

    function withdrawAll() external whenNotPaused nonReentrant {
        uint256 bal = balances[msg.sender];
        if (bal == 0) revert InsufficientBalance();

        uint256 fee = _calculateWithdrawalFee(bal);
        uint256 net = bal - fee;

        balances[msg.sender] = 0;
        totalDeposits -= bal;
        if (fee > 0) collectedFees += fee;

        uint256 contractBal = stableToken.balanceOf(address(this));
        if (contractBal < net + collectedFees) revert NoContractBalance();

        stableToken.safeTransfer(msg.sender, net);

        emit WithdrawAll(msg.sender, bal, fee, net);
    }

    function partialWithdraw(uint256 percentage) external whenNotPaused nonReentrant {
        if (percentage == 0 || percentage > 100) revert InvalidPercent();
        uint256 bal = balances[msg.sender];
        if (bal == 0) revert InsufficientBalance();

        uint256 amt = (bal * percentage) / 100;
        withdraw(amt);
    }

    /* ========== BULK OPS ========== */
    function bulkDeposit(address[] calldata users, uint256[] calldata amounts)
        external
        onlyAuthorizedOrOwner
        whenNotPaused
        nonReentrant
    {
        if (users.length != amounts.length) revert ArrayLengthMismatch();
        uint256 len = users.length;

        for (uint256 i; i < len; ) {
            uint256 req = amounts[i];
            if (req == 0) revert AmountZero();

            uint256 before = stableToken.balanceOf(address(this));
            stableToken.safeTransferFrom(msg.sender, address(this), req);
            uint256 received = stableToken.balanceOf(address(this)) - before;

            if (received < minimumDeposit) revert AmountBelowMinimum();

            _addBalance(users[i], received);
            emit Deposited(users[i], req, received, balances[users[i]]);

            unchecked { ++i; }
        }
    }

    /* ========== VIEW HELPERS ========== */
    function calculateWithdrawalFee(uint256 amount) external view returns (uint256) {
        return _calculateWithdrawalFee(amount);
    }

    function withdrawableAmount(address user) external view returns (uint256) {
        uint256 bal = balances[user];
        if (bal == 0) return 0;
        return bal - _calculateWithdrawalFee(bal);
    }

    function userInfo(address user) external view returns (
        uint256 balance,
        uint256 lastDeposit,
        uint256 withdrawable
    ) {
        balance = balances[user];
        lastDeposit = lastDepositTime[user];
        withdrawable = (balance == 0) ? 0 : balance - _calculateWithdrawalFee(balance);
    }

    function getContractStats() external view returns (
        uint256 users,
        uint256 deposits,
        uint256 fees,
        uint256 contractBalance,
        uint256 avgBalance
    ) {
        users = totalUsers;
        deposits = totalDeposits;
        fees = collectedFees;
        contractBalance = stableToken.balanceOf(address(this));
        avgBalance = users > 0 ? deposits / users : 0;
    }

    function contractHealth() external view returns (bool healthy, uint256 contractBalance, uint256 deposits) {
        contractBalance = stableToken.balanceOf(address(this));
        deposits = totalDeposits;
        healthy = contractBalance >= deposits + collectedFees;
    }

    /* ========== OWNER OPS ========== */
    function authorizeUser(address user, bool auth) external onlyOwner {
        authorizedUsers[user] = auth;
        emit AdminAuthorized(user, auth);
    }

    function setMinimumDeposit(uint256 newMin) external onlyOwner {
        uint256 old = minimumDeposit;
        minimumDeposit = newMin;
        emit MinimumDepositUpdated(old, newMin);
    }

    function setWithdrawalFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();
        uint256 old = withdrawalFee;
        withdrawalFee = newFee;
        emit WithdrawalFeeUpdated(old, newFee);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = t;
        emit TreasuryUpdated(old, t);
    }

    function sweepCollectedFees(uint256 amt) external onlyOwner nonReentrant {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (amt == 0) revert AmountZero();
        if (amt > collectedFees) revert AmountExceedsCollectedFees();

        collectedFees -= amt;
        stableToken.safeTransfer(treasury, amt);

        emit FeesClaimed(treasury, amt);
    }

    function rebalance() external onlyOwner {
        emit Rebalanced(totalDeposits, stableToken.balanceOf(address(this)));
    }

    function emergencyWithdraw(uint256 amt) external onlyOwner nonReentrant {
        if (!paused()) revert RescueNotAllowed();
        stableToken.safeTransfer(owner(), amt);
        emit EmergencyWithdrawal(owner(), amt);
    }

    function rescueNonStableToken(address token, address to, uint256 amt) external onlyOwner nonReentrant {
        if (token == address(stableToken)) revert RescueNotAllowed();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amt);
        emit RescueToken(token, to, amt);
    }

    /* ========== INTERNAL HELPERS ========== */
    function _calculateWithdrawalFee(uint256 amount) internal view returns (uint256) {
        return (amount * withdrawalFee) / 10_000;
    }

    function _addBalance(address user, uint256 amount) internal {
        if (!_isUser[user]) {
            _isUser[user] = true;
            totalUsers++;
        }
        balances[user] += amount;
        totalDeposits += amount;
        lastDepositTime[user] = block.timestamp;
    }

    /* ========== PAUSE CONTROL ========== */
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ========== FALLBACKS ========== */
    receive() external payable { revert(); }
    fallback() external payable { revert(); }
}
