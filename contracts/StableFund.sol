// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

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
    error Blacklisted();
    error WithdrawalLocked();

    /* ========== STATE ========== */
    IERC20 public immutable stableToken;

    address public treasury;                 
    uint256 public totalDeposits;            
    uint256 public collectedFees;            
    uint256 public minimumDeposit;           
    uint256 public withdrawalFee;            
    uint256 public lockPeriod; // seconds users must wait before withdrawing

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;
    mapping(address => bool) private _isUser;
    mapping(address => bool) public blacklisted;

    uint256 public totalUsers;

    /* ========== CONSTANTS ========== */
    uint256 public constant MAX_WITHDRAWAL_FEE_BP = 1_000; // 10%

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 requested, uint256 received, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 gross, uint256 fee, uint256 net, uint256 newBalance);
    event WithdrawAll(address indexed user, uint256 gross, uint256 fee, uint256 net);

    event BlacklistUpdated(address indexed user, bool status);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    event Rebalanced(uint256 totalDeposits, uint256 contractBalance);
    event AdminAuthorized(address indexed user, bool authorized);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesClaimed(address indexed treasury, uint256 amount);
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    /* ========== CONSTRUCTOR ========== */
    constructor(address tokenAddress, uint256 _minimumDeposit, uint256 _withdrawalFee, uint256 _lockPeriod) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_withdrawalFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();

        stableToken = IERC20(tokenAddress);
        minimumDeposit = _minimumDeposit;
        withdrawalFee = _withdrawalFee;
        lockPeriod = _lockPeriod;

        authorizedUsers[msg.sender] = true;
    }

    /* ========== MODIFIERS ========== */
    modifier onlyAuthorizedOrOwner() {
        if (msg.sender != owner() && !authorizedUsers[msg.sender]) revert NotAuthorized();
        _;
    }
    modifier notBlacklisted() {
        if (blacklisted[msg.sender]) revert Blacklisted();
        _;
    }

    /* ========== USER ACTIONS ========== */
    function deposit(uint256 requestedAmount) external whenNotPaused nonReentrant notBlacklisted {
        if (requestedAmount == 0) revert AmountZero();

        uint256 before = stableToken.balanceOf(address(this));
        stableToken.safeTransferFrom(msg.sender, address(this), requestedAmount);
        uint256 received = stableToken.balanceOf(address(this)) - before;

        if (received < minimumDeposit) revert AmountBelowMinimum();

        _addBalance(msg.sender, received);

        emit Deposited(msg.sender, requestedAmount, received, balances[msg.sender]);
    }

    function withdraw(uint256 amount) public whenNotPaused nonReentrant notBlacklisted {
        if (amount == 0) revert AmountZero();
        uint256 bal = balances[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        if (block.timestamp < lastDepositTime[msg.sender] + lockPeriod) revert WithdrawalLocked();

        uint256 fee = _calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        balances[msg.sender] = bal - amount;
        totalDeposits -= amount;
        if (fee > 0) collectedFees += fee;

        stableToken.safeTransfer(msg.sender, net);
        emit Withdrawn(msg.sender, amount, fee, net, balances[msg.sender]);
    }

    /* ========== ADMIN OPS ========== */
    function updateBlacklist(address user, bool status) external onlyOwner {
        blacklisted[user] = status;
        emit BlacklistUpdated(user, status);
    }

    function setLockPeriod(uint256 newPeriod) external onlyOwner {
        uint256 old = lockPeriod;
        lockPeriod = newPeriod;
        emit LockPeriodUpdated(old, newPeriod);
    }

    /* ========== VIEW HELPERS ========== */
    function userShare(address user) external view returns (uint256 percent) {
        if (totalDeposits == 0) return 0;
        percent = (balances[user] * 1e18) / totalDeposits; // in 1e18 precision
    }
}
