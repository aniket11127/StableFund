// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  StableFund - further refinements
  - Uses OpenZeppelin's SafeERC20, ReentrancyGuard, Pausable, Ownable
  - Handles fee-on-transfer tokens for deposits by measuring actual received amount
  - Replaces custom reentrancy guard with OZ ReentrancyGuard
  - Adds withdrawAll(), rescueNonStableToken(), sweepCollectedFeesToTreasury()
  - Adds view helpers and stronger accounting checks
  - Keeps collectedFees accounting separate from user deposits
  - Maintains backwards-compatible external API where practical
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
    address public treasury;                 // where fees are claimed to
    uint256 public totalDeposits;            // sum of recorded user deposits (does NOT include collectedFees)
    uint256 public collectedFees;            // fees accumulated (in token smallest units)
    uint256 public minimumDeposit;           // in token smallest units
    uint256 public withdrawalFee;            // basis points (1 bp = 0.01%), cap enforced

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;

    mapping(address => bool) private _isUser;
    uint256 public totalUsers;

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 requested, uint256 actualReceived);
    event Withdrawn(address indexed user, uint256 gross, uint256 fee, uint256 net);
    event Rebalanced(uint256 totalDeposits, uint256 contractBalance);
    event AdminAuthorized(address indexed user, bool authorized);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesClaimed(address indexed treasury, uint256 amount);
    event EmergencyWithdrawal(address indexed admin, uint256 amount);
    event RescueToken(address indexed token, address indexed to, uint256 amount);
    event WithdrawAll(address indexed user, uint256 gross, uint256 fee, uint256 net);

    /* ========== CONSTANTS ========== */
    uint256 public constant MAX_WITHDRAWAL_FEE_BP = 1000; // 10%

    /* ========== CONSTRUCTOR ========== */

    /// @param tokenAddress address of the stable ERC20 token
    /// @param _minimumDeposit minimum deposit in token smallest units
    /// @param _withdrawalFee withdrawal fee in basis points (50 = 0.5%)
    constructor(address tokenAddress, uint256 _minimumDeposit, uint256 _withdrawalFee) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_withdrawalFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();

        stableToken = IERC20(tokenAddress);
        minimumDeposit = _minimumDeposit;
        withdrawalFee = _withdrawalFee;

        // owner is set by Ownable (msg.sender)
        authorizedUsers[msg.sender] = true;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyAuthorizedOrOwner() {
        if (owner() != msg.sender && !authorizedUsers[msg.sender]) revert NotAuthorized();
        _;
    }

    /* ========== DEPOSIT / WITHDRAW ========== */

    /// @notice deposit tokens from msg.sender. Handles fee-on-transfer tokens by measuring actual received.
    function deposit(uint256 requestedAmount) external whenNotPaused nonReentrant {
        if (requestedAmount == 0) revert AmountZero();

        // record contract balance before transferFrom
        uint256 before = stableToken.balanceOf(address(this));
        stableToken.safeTransferFrom(msg.sender, address(this), requestedAmount);
        uint256 after = stableToken.balanceOf(address(this));

        // actual received might be less than requested for tokens with transfer fees
        uint256 received = after - before;
        if (received < minimumDeposit) revert AmountBelowMinimum();

        _addBalance(msg.sender, received);
        emit Deposited(msg.sender, requestedAmount, received);
    }

    /// @notice withdraw exact `amount` (fee applied)
    function withdraw(uint256 amount) public whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        uint256 userBal = balances[msg.sender];
        if (userBal < amount) revert InsufficientBalance();

        uint256 fee = _calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        // adjust internal accounting BEFORE transfer
        balances[msg.sender] = userBal - amount;
        totalDeposits -= amount;

        if (fee > 0) {
            collectedFees += fee;
        }

        // ensure contract actually has enough to pay net (consider collectedFees kept in contract too)
        uint256 contractBal = stableToken.balanceOf(address(this));
        // contractBal includes collectedFees; we only require contractBal >= net + collectedFees
        if (contractBal < net + collectedFees) revert NoContractBalance();

        stableToken.safeTransfer(msg.sender, net);
        emit Withdrawn(msg.sender, amount, fee, net);
    }

    /// @notice withdraw the entire recorded balance (convenience)
    function withdrawAll() external whenNotPaused nonReentrant {
        uint256 userBal = balances[msg.sender];
        if (userBal == 0) revert InsufficientBalance();
        uint256 fee = _calculateWithdrawalFee(userBal);
        uint256 net = userBal - fee;

        // accounting before external transfer
        balances[msg.sender] = 0;
        totalDeposits -= userBal;
        if (fee > 0) collectedFees += fee;

        uint256 contractBal = stableToken.balanceOf(address(this));
        if (contractBal < net + collectedFees) revert NoContractBalance();

        stableToken.safeTransfer(msg.sender, net);
        emit WithdrawAll(msg.sender, userBal, fee, net);
    }

    /// @notice partial withdraw by percentage (1-100)
    function partialWithdraw(uint256 percentage) external whenNotPaused nonReentrant {
        if (percentage == 0 || percentage > 100) revert InvalidPercent();
        uint256 userBal = balances[msg.sender];
        if (userBal == 0) revert InsufficientBalance();

        uint256 amount = (userBal * percentage) / 100;
        if (amount == 0) revert AmountZero();

        withdraw(amount);
    }

    /* ========== BULK OPERATIONS ========== */

    /// @notice deposit for many users using tokens from msg.sender (handles fee-on-transfer)
    /// Caller must approve the contract for the sum of `amounts` (requested amounts).
    function bulkDeposit(address[] calldata users, uint256[] calldata amounts)
        external
        onlyAuthorizedOrOwner
        whenNotPaused
        nonReentrant
    {
        if (users.length != amounts.length) revert ArrayLengthMismatch();
        uint256 len = users.length;

        // To support fee-on-transfer tokens we will measure before/after once per call and
        // allocate received tokens in proportion to requested amounts.
        // Simpler approach: do individual transferFroms and measure per-loop (safer).
        for (uint256 i = 0; i < len; ) {
            address u = users[i];
            uint256 req = amounts[i];
            if (req == 0) revert AmountZero();

            uint256 before = stableToken.balanceOf(address(this));
            stableToken.safeTransferFrom(msg.sender, address(this), req);
            uint256 after = stableToken.balanceOf(address(this));
            uint256 received = after - before;

            if (received < minimumDeposit) revert AmountBelowMinimum();

            _addBalance(u, received);
            emit Deposited(u, req, received);

            unchecked { ++i; }
        }
    }

    /* ========== VIEWS / HELPERS ========== */

    /// @notice calculate fee in token units for a given amount
    function calculateWithdrawalFee(uint256 amount) external view returns (uint256) {
        return _calculateWithdrawalFee(amount);
    }

    function _calculateWithdrawalFee(uint256 amount) internal view returns (uint256) {
        return (amount * withdrawalFee) / 10000;
    }

    /// @notice returns withdrawable amount accounting current fee setting
    function withdrawableAmount(address user) external view returns (uint256) {
        uint256 bal = balances[user];
        if (bal == 0) return 0;
        uint256 fee = _calculateWithdrawalFee(bal);
        return bal - fee;
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
    }

    /* ========== ADMIN / MANAGEMENT ========== */

    /// @notice owner can authorize other users for bulk ops
    function authorizeUser(address user, bool authorized) external onlyOwner {
        authorizedUsers[user] = authorized;
        emit AdminAuthorized(user, authorized);
    }

    /// @notice set minimum deposit (in token smallest units)
    function setMinimumDeposit(uint256 newMinimum) external onlyOwner {
        uint256 old = minimumDeposit;
        minimumDeposit = newMinimum;
        emit MinimumDepositUpdated(old, newMinimum);
    }

    /// @notice set withdrawal fee in basis points (max 1000 => 10%)
    function setWithdrawalFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_WITHDRAWAL_FEE_BP) revert FeeTooHigh();
        uint256 old = withdrawalFee;
        withdrawalFee = newFee;
        emit WithdrawalFeeUpdated(old, newFee);
    }

    /// @notice set treasury where collected fees will be claimed to
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    /// @notice owner can transfer accumulated collectedFees to the treasury
    function sweepCollectedFeesToTreasury(uint256 amount) external onlyOwner nonReentrant {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (amount == 0) revert AmountZero();
        if (amount > collectedFees) revert AmountExceedsCollectedFees();

        collectedFees -= amount;
        stableToken.safeTransfer(treasury, amount);
        emit FeesClaimed(treasury, amount);
    }

    /// @notice view helper: current contract balance available to pay users (excluding collectedFees)
    function availableForUsers() public view returns (uint256) {
        uint256 contractBal = stableToken.balanceOf(address(this));
        if (contractBal <= collectedFees) return 0;
        return contractBal - collectedFees;
    }

    /// @notice admin-only rebalance/check (emit only)
    function rebalance() external onlyOwner {
        uint256 contractBalance = stableToken.balanceOf(address(this));
        emit Rebalanced(totalDeposits, contractBalance);
    }

    /// @notice emergency withdraw to owner (only while paused)
    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
        if (!paused()) revert RescueNotAllowed();
        uint256 contractBal = stableToken.balanceOf(address(this));
        if (amount > contractBal) revert InsufficientBalance();
        // Note: this withdraws raw tokens from contract, and will include collectedFees too.
        stableToken.safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(owner(), amount);
    }

    /// @notice rescue any non-stable token accidentally sent to this contract
    function rescueNonStableToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(stableToken)) revert RescueNotAllowed(); // don't allow sweeping the stable token
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    /* ========== INTERNAL HELPERS ========== */

    function _addBalance(address user, uint256 amount) internal {
        if (!_isUser[user]) {
            _isUser[user] = true;
            totalUsers += 1;
        }
        balances[user] += amount;
        totalDeposits += amount;
        lastDepositTime[user] = block.timestamp;
    }

    /* ========== PAUSE / UNPAUSE (owner) ========== */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== FALLBACKS ========== */

    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }
}
