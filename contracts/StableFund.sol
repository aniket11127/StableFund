// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  StableFund - extended refinements
  - SafeERC20 + ReentrancyGuard + Pausable + Ownable
  - Fee-exempt addresses
  - withdrawAll, bulkDeposit, sweepCollectedFees, rescueNonStableToken, emergencyWithdraw
  - stronger checks-effects-interactions and contract-balance assertions
  - useful view helpers: availableForUsers, withdrawableAmount, userInfo, getContractStats
  - blacklist, lockPeriod retained
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
    error Blacklisted();
    error WithdrawalLocked();

    /* ========== STATE ========== */
    IERC20 public immutable stableToken;

    address public treasury;                 // where fees can be swept
    uint256 public totalDeposits;            // user deposit accounting (excludes collectedFees)
    uint256 public collectedFees;            // accumulated fees (token units)
    uint256 public minimumDeposit;           // smallest token units
    uint256 public withdrawalFee;            // basis points (1 bp = 0.01%)
    uint256 public lockPeriod;               // seconds users must wait after deposit before withdraw

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;
    mapping(address => bool) private _isUser;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public feeExempt; // addresses exempted from withdrawal fee (true => exempt)

    uint256 public totalUsers;

    /* ========== CONSTANTS ========== */
    uint256 public constant MAX_WITHDRAWAL_FEE_BP = 1_000; // 10%

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 requested, uint256 received, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 gross, uint256 fee, uint256 net, uint256 newBalance);
    event WithdrawAll(address indexed user, uint256 gross, uint256 fee, uint256 net);
    event BulkDepositProcessed(uint256 count, uint256 totalReceived);
    event BlacklistUpdated(address indexed user, bool status);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event FeeExemptUpdated(address indexed account, bool exempt);
    event AdminAuthorized(address indexed user, bool authorized);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesClaimed(address indexed treasury, uint256 amount);
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address tokenAddress,
        uint256 _minimumDeposit,
        uint256 _withdrawalFee,
        uint256 _lockPeriod
    ) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_withdrawalFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();

        stableToken = IERC20(tokenAddress);
        minimumDeposit = _minimumDeposit;
        withdrawalFee = _withdrawalFee;
        lockPeriod = _lockPeriod;

        authorizedUsers[msg.sender] = true;
        feeExempt[msg.sender] = true; // deployer typically exempt (optional)
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

    /// @notice Deposit requested amount from caller. Supports fee-on-transfer tokens by measuring actual received.
    function deposit(uint256 requestedAmount) external whenNotPaused nonReentrant notBlacklisted {
        if (requestedAmount == 0) revert AmountZero();

        uint256 before = stableToken.balanceOf(address(this));
        stableToken.safeTransferFrom(msg.sender, address(this), requestedAmount);
        uint256 received = stableToken.balanceOf(address(this)) - before;

        if (received < minimumDeposit) revert AmountBelowMinimum();

        _addBalance(msg.sender, received);
        emit Deposited(msg.sender, requestedAmount, received, balances[msg.sender]);
    }

    /// @notice Withdraw an exact amount (fee applied unless exempt)
    function withdraw(uint256 amount) public whenNotPaused nonReentrant notBlacklisted {
        if (amount == 0) revert AmountZero();
        uint256 bal = balances[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        if (block.timestamp < lastDepositTime[msg.sender] + lockPeriod) revert WithdrawalLocked();

        bool isExempt = feeExempt[msg.sender];
        uint256 fee = isExempt ? 0 : _calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        // compute post-state and assert contract has funds BEFORE storage mutation
        uint256 contractBal = stableToken.balanceOf(address(this));
        uint256 postCollectedFees = collectedFees + fee;
        // require contract balance >= net + postCollectedFees (i.e. users' funds + fees)
        if (contractBal < net + postCollectedFees) revert NoContractBalance();

        // EFFECTS
        balances[msg.sender] = bal - amount;
        totalDeposits -= amount;
        if (fee > 0) collectedFees = postCollectedFees;

        // INTERACTION
        stableToken.safeTransfer(msg.sender, net);

        emit Withdrawn(msg.sender, amount, fee, net, balances[msg.sender]);
    }

    /// @notice Withdraw full recorded balance (fee applies unless exempt)
    function withdrawAll() external whenNotPaused nonReentrant notBlacklisted {
        uint256 bal = balances[msg.sender];
        if (bal == 0) revert InsufficientBalance();
        if (block.timestamp < lastDepositTime[msg.sender] + lockPeriod) revert WithdrawalLocked();

        bool isExempt = feeExempt[msg.sender];
        uint256 fee = isExempt ? 0 : _calculateWithdrawalFee(bal);
        uint256 net = bal - fee;

        uint256 contractBal = stableToken.balanceOf(address(this));
        uint256 postCollectedFees = collectedFees + fee;
        if (contractBal < net + postCollectedFees) revert NoContractBalance();

        // EFFECTS
        balances[msg.sender] = 0;
        totalDeposits -= bal;
        if (fee > 0) collectedFees = postCollectedFees;

        // INTERACTION
        stableToken.safeTransfer(msg.sender, net);

        emit WithdrawAll(msg.sender, bal, fee, net);
    }

    /* ========== BULK OPS ========== */

    /// @notice Bulk deposit per-user; measures received per transfer (safe for fee-on-transfer tokens).
    function bulkDeposit(address[] calldata users, uint256[] calldata amounts)
        external
        onlyAuthorizedOrOwner
        whenNotPaused
        nonReentrant
    {
        if (users.length != amounts.length) revert ArrayLengthMismatch();
        uint256 len = users.length;
        uint256 totalReceived = 0;

        for (uint256 i = 0; i < len; ) {
            address u = users[i];
            uint256 req = amounts[i];
            if (req == 0) revert AmountZero();

            uint256 before = stableToken.balanceOf(address(this));
            stableToken.safeTransferFrom(msg.sender, address(this), req);
            uint256 received = stableToken.balanceOf(address(this)) - before;

            if (received < minimumDeposit) revert AmountBelowMinimum();

            _addBalance(u, received);
            totalReceived += received;
            emit Deposited(u, req, received, balances[u]);

            unchecked { ++i; }
        }

        emit BulkDepositProcessed(len, totalReceived);
    }

    /* ========== OWNER / ADMIN OPS ========== */

    /// @notice Authorize account for bulk ops
    function authorizeUser(address user, bool auth) external onlyOwner {
        authorizedUsers[user] = auth;
        emit AdminAuthorized(user, auth);
    }

    /// @notice Update blacklist
    function updateBlacklist(address user, bool status) external onlyOwner {
        blacklisted[user] = status;
        emit BlacklistUpdated(user, status);
    }

    /// @notice Mark account fee-exempt or not
    function setFeeExempt(address account, bool exempt) external onlyOwner {
        feeExempt[account] = exempt;
        emit FeeExemptUpdated(account, exempt);
    }

    /// @notice set minimum deposit (in token smallest units)
    function setMinimumDeposit(uint256 newMin) external onlyOwner {
        uint256 old = minimumDeposit;
        minimumDeposit = newMin;
        emit MinimumDepositUpdated(old, newMin);
    }

    /// @notice set withdrawal fee (bp)
    function setWithdrawalFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();
        uint256 old = withdrawalFee;
        withdrawalFee = newFee;
        emit WithdrawalFeeUpdated(old, newFee);
    }

    /// @notice set treasury
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = t;
        emit TreasuryUpdated(old, t);
    }

    /// @notice sweep collected fees to treasury
    function sweepCollectedFees(uint256 amount) external onlyOwner nonReentrant {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (amount == 0) revert AmountZero();
        if (amount > collectedFees) revert AmountExceedsCollectedFees();

        collectedFees -= amount;
        stableToken.safeTransfer(treasury, amount);
        emit FeesClaimed(treasury, amount);
    }

    /// @notice emergency withdraw raw tokens (only when paused)
    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
        if (!paused()) revert NoContractBalance();
        uint256 contractBal = stableToken.balanceOf(address(this));
        if (amount > contractBal) revert InsufficientBalance();

        stableToken.safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(owner(), amount);
    }

    /// @notice rescue non-stable tokens accidentally sent
    function rescueNonStableToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(stableToken)) revert RescueNotAllowed();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    /// @notice Set lockPeriod
    function setLockPeriod(uint256 newLock) external onlyOwner {
        uint256 old = lockPeriod;
        lockPeriod = newLock;
        emit LockPeriodUpdated(old, newLock);
    }

    /* ========== VIEWS / HELPERS ========== */

    function _calculateWithdrawalFee(uint256 amount) internal view returns (uint256) {
        return (amount * withdrawalFee) / 10_000;
    }

    /// @notice amount a user would receive if they withdraw full balance now (after fee)
    function withdrawableAmount(address user) public view returns (uint256) {
        uint256 bal = balances[user];
        if (bal == 0) return 0;
        if (feeExempt[user]) return bal;
        uint256 fee = _calculateWithdrawalFee(bal);
        return bal - fee;
    }

    /// @notice contract balance available for user withdrawals (excl collectedFees)
    function availableForUsers() public view returns (uint256) {
        uint256 cb = stableToken.balanceOf(address(this));
        if (cb <= collectedFees) return 0;
        return cb - collectedFees;
    }

    function userInfo(address user) external view returns (
        uint256 balance,
        uint256 lastDeposit,
        uint256 withdrawable,
        bool isBlacklisted,
        bool isFeeExempt
    ) {
        balance = balances[user];
        lastDeposit = lastDepositTime[user];
        withdrawable = withdrawableAmount(user);
        isBlacklisted = blacklisted[user];
        isFeeExempt = feeExempt[user];
    }

    function getContractStats() external view returns (
        uint256 _totalUsers,
        uint256 _totalDeposits,
        uint256 _collectedFees,
        uint256 contractBalance,
        uint256 avgBalance
    ) {
        _totalUsers = totalUsers;
        _totalDeposits = totalDeposits;
        _collectedFees = collectedFees;
        contractBalance = stableToken.balanceOf(address(this));
        avgBalance = _totalUsers > 0 ? _totalDeposits / _totalUsers : 0;
    }

    /* ========== INTERNAL ========== */

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
