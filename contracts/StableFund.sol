// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
 Refined StableFund
 - Uses OpenZeppelin's SafeERC20 wrapper for safe token interactions
 - Tracks collected withdrawal fees separately (collectedFees)
 - Admin can set a treasury address and claim collected fees
 - Improved events and custom errors for gas savings
 - Kept original behaviour / API mostly same but safer/cleaner
*/

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StableFund {
    using SafeERC20 for IERC20;

    /* ========== ERRORS (gas efficient) ========== */
    error ZeroAddress();
    error NotAdmin();
    error ContractPaused();
    error AmountZero();
    error AmountBelowMinimum();
    error InsufficientBalance();
    error ArrayLengthMismatch();
    error FeeTooHigh();
    error InvalidPercent();
    error NotAuthorized();
    error TransferFailed();
    error NotPaused();

    /* ========== STATE ========== */

    address public admin;
    IERC20 public immutable stableToken;
    address public treasury; // where fees are claimed to
    uint256 public totalDeposits;
    uint256 public collectedFees; // accumulated fees from withdrawals (in token smallest units)

    /// minimum deposit in token smallest units
    uint256 public minimumDeposit;

    /// withdrawalFee in basis points (1 bp = 0.01%). e.g., 50 => 0.5%
    uint256 public withdrawalFee;

    bool public paused;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;

    /// track unique users for contract stats
    mapping(address => bool) private _isUser;
    uint256 public totalUsers;

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 amount);
    /// gross = requested amount, fee = fee taken, net = amount sent to user
    event Withdrawn(address indexed user, uint256 gross, uint256 fee, uint256 net);
    event Rebalanced(uint256 totalDeposits, uint256 contractBalance);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(bool paused);
    event UserAuthorized(address indexed user, bool authorized);
    event EmergencyWithdrawal(address indexed admin, uint256 amount);
    event FeesClaimed(address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ========== REENTRANCY GUARD ========== */
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyAuthorizedOrAdmin() {
        if (msg.sender != admin && !authorizedUsers[msg.sender]) revert NotAuthorized();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @param tokenAddress ERC20 stable token address
    /// @param _minimumDeposit minimum deposit in token smallest unit (e.g., for 18-decimals pass 100 * 10**18)
    /// @param _withdrawalFee basis points (50 = 0.5%)
    constructor(address tokenAddress, uint256 _minimumDeposit, uint256 _withdrawalFee) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_withdrawalFee > 1000) revert FeeTooHigh(); // cap 10%
        admin = msg.sender;
        stableToken = IERC20(tokenAddress);
        minimumDeposit = _minimumDeposit;
        withdrawalFee = _withdrawalFee;
        authorizedUsers[msg.sender] = true; // admin authorized
        _status = _NOT_ENTERED;
    }

    /* ========== DEPOSIT / WITHDRAW ========== */

    /// @notice deposit tokens from msg.sender
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        if (amount < minimumDeposit) revert AmountBelowMinimum();

        // pull tokens safely
        stableToken.safeTransferFrom(msg.sender, address(this), amount);

        _addBalance(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice withdraw `amount` (fee is applied)
    function withdraw(uint256 amount) public whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        uint256 userBal = balances[msg.sender];
        if (userBal < amount) revert InsufficientBalance();

        uint256 fee = calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        // update accounting BEFORE external call
        balances[msg.sender] = userBal - amount;
        totalDeposits -= amount;

        // record fee for later claim
        if (fee > 0) {
            collectedFees += fee;
        }

        // transfer net amount
        stableToken.safeTransfer(msg.sender, net);

        emit Withdrawn(msg.sender, amount, fee, net);
    }

    /// @notice partial withdraw by percentage (1-100)
    function partialWithdraw(uint256 percentage) external whenNotPaused {
        if (percentage == 0 || percentage > 100) revert InvalidPercent();
        uint256 userBal = balances[msg.sender];
        if (userBal == 0) revert InsufficientBalance();

        uint256 amount = (userBal * percentage) / 100;
        // amount could be zero if userBal < 100 and percentage small; guard:
        if (amount == 0) revert AmountZero();

        withdraw(amount);
    }

    /* ========== BULK OPERATIONS (authorized users) ========== */

    /// @notice deposit on behalf of many users - authorized caller must have approved tokens to this contract
    function bulkDeposit(address[] calldata users, uint256[] calldata amounts)
        external
        onlyAuthorizedOrAdmin
        whenNotPaused
        nonReentrant
    {
        if (users.length != amounts.length) revert ArrayLengthMismatch();
        uint256 len = users.length;

        for (uint256 i = 0; i < len; ) {
            address u = users[i];
            uint256 amt = amounts[i];
            if (amt < minimumDeposit) revert AmountBelowMinimum();

            stableToken.safeTransferFrom(msg.sender, address(this), amt);

            _addBalance(u, amt);
            emit Deposited(u, amt);

            unchecked { ++i; }
        }
    }

    /* ========== VIEWS / HELPERS ========== */

    /// @notice calculate fee (basis points)
    function calculateWithdrawalFee(uint256 amount) public view returns (uint256) {
        return (amount * withdrawalFee) / 10000;
    }

    /// @notice get user information
    function getUserInfo(address user) external view returns (
        uint256 balance,
        uint256 lastDeposit,
        bool isAuthorized,
        uint256 withdrawableAmount
    ) {
        balance = balances[user];
        lastDeposit = lastDepositTime[user];
        isAuthorized = authorizedUsers[user];

        if (balance > 0) {
            uint256 fee = calculateWithdrawalFee(balance);
            withdrawableAmount = balance - fee;
        } else {
            withdrawableAmount = 0;
        }
    }

    /// @notice return basic contract stats
    function getContractStats() external view returns (
        uint256 _totalUsers,
        uint256 contractBalance,
        uint256 averageBalance,
        uint256 _collectedFees
    ) {
        contractBalance = stableToken.balanceOf(address(this));
        _totalUsers = totalUsers;
        averageBalance = 0;
        if (_totalUsers > 0) {
            averageBalance = totalDeposits / _totalUsers;
        }
        _collectedFees = collectedFees;
        return (_totalUsers, contractBalance, averageBalance, _collectedFees);
    }

    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }

    function getContractBalance() external view returns (uint256) {
        return stableToken.balanceOf(address(this));
    }

    function isUserAuthorized(address user) external view returns (bool) {
        return authorizedUsers[user];
    }

    function getLastDepositTime(address user) external view returns (uint256) {
        return lastDepositTime[user];
    }

    /// @notice health check
    function isContractHealthy() external view returns (bool healthy, uint256 contractBalance, uint256 _totalDeposits) {
        contractBalance = stableToken.balanceOf(address(this));
        _totalDeposits = totalDeposits;
        healthy = contractBalance >= _totalDeposits;
        return (healthy, contractBalance, _totalDeposits);
    }

    /* ========== ADMIN / MANAGEMENT ========== */

    /// @notice change admin
    function changeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address old = admin;
        admin = newAdmin;
        authorizedUsers[newAdmin] = true;
        emit AdminChanged(old, newAdmin);
    }

    /// @notice set minimum deposit (in token smallest units)
    function setMinimumDeposit(uint256 newMinimum) external onlyAdmin {
        uint256 old = minimumDeposit;
        minimumDeposit = newMinimum;
        emit MinimumDepositUpdated(old, newMinimum);
    }

    /// @notice set withdrawal fee in basis points (max 1000 => 10%)
    function setWithdrawalFee(uint256 newFee) external onlyAdmin {
        if (newFee > 1000) revert FeeTooHigh();
        uint256 old = withdrawalFee;
        withdrawalFee = newFee;
        emit WithdrawalFeeUpdated(old, newFee);
    }

    function pauseContract(bool _paused) external onlyAdmin {
        paused = _paused;
        emit ContractPaused(_paused);
    }

    function authorizeUser(address user, bool authorized) external onlyAdmin {
        authorizedUsers[user] = authorized;
        emit UserAuthorized(user, authorized);
    }

    /// @notice set treasury where collected fees will be claimed to
    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    /// @notice admin can claim collected fees to treasury
    function claimFees(uint256 amount) external onlyAdmin nonReentrant {
        if (treasury == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        if (amount > collectedFees) revert InsufficientBalance();

        collectedFees -= amount;
        stableToken.safeTransfer(treasury, amount);

        emit FeesClaimed(treasury, amount);
    }

    /// @notice rebalance check (no automatic external calls, just report)
    function rebalance() external onlyAdmin {
        uint256 contractBalance = stableToken.balanceOf(address(this));
        // implement any reconciliation here (currently only emits)
        emit Rebalanced(totalDeposits, contractBalance);
    }

    /// @notice emergency withdraw to admin — only allowed when paused
    function emergencyWithdraw(uint256 amount) external onlyAdmin nonReentrant {
        if (!paused) revert NotPaused();
        uint256 contractBal = stableToken.balanceOf(address(this));
        if (amount > contractBal) revert InsufficientBalance();
        stableToken.safeTransfer(admin, amount);
        emit EmergencyWithdrawal(admin, amount);
    }

    /* ========== INTERNAL HELPERS ========== */

    /// @dev add balance and update bookkeeping
    function _addBalance(address user, uint256 amount) internal {
        if (!_isUser[user]) {
            _isUser[user] = true;
            totalUsers += 1;
        }
        balances[user] += amount;
        totalDeposits += amount;
        lastDepositTime[user] = block.timestamp;
    }

    /* ========== FALLBACKS ========== */

    receive() external payable {
        // reject ETH
        revert();
    }

    fallback() external payable {
        revert();
    }
}
