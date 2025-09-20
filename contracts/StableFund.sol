// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Minimal ERC20 interface used by the contract
interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract StableFund {
    /* ========== STATE ========== */

    address public admin;
    IERC20 public immutable stableToken;
    uint256 public totalDeposits;

    /// @notice minimum deposit in token smallest units (i.e., considering token decimals)
    uint256 public minimumDeposit;

    /// @notice withdrawalFee in basis points (1 bp = 0.01%). e.g., 50 => 0.5%
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
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event Rebalanced(uint256 totalDeposits, uint256 contractBalance);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(bool paused);
    event UserAuthorized(address indexed user, bool authorized);
    event EmergencyWithdrawal(address indexed admin, uint256 amount);

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
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier onlyAuthorizedOrAdmin() {
        require(msg.sender == admin || authorizedUsers[msg.sender], "Not authorized");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @param tokenAddress ERC20 stable token address
    /// @param _minimumDeposit minimum deposit in token smallest unit (e.g., for 18-decimals pass 100 * 10**18)
    /// @param _withdrawalFee basis points (50 = 0.5%)
    constructor(address tokenAddress, uint256 _minimumDeposit, uint256 _withdrawalFee) {
        require(tokenAddress != address(0), "Zero token address");
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
        require(amount > 0, "Amount must be > 0");
        require(amount >= minimumDeposit, "Amount below minimum");

        // pull tokens
        require(stableToken.transferFrom(msg.sender, address(this), amount), "TransferFrom failed");

        _addBalance(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice withdraw `amount` (fee is applied)
    function withdraw(uint256 amount) public whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(balances[msg.sender] >= amount, "Insufficient balance");

        uint256 fee = calculateWithdrawalFee(amount);
        uint256 net = amount - fee;

        // update accounting BEFORE external call
        balances[msg.sender] -= amount;
        totalDeposits -= amount;

        // update user existence if balance becomes zero (optional)
        if (balances[msg.sender] == 0 && _isUser[msg.sender]) {
            // keep totalUsers as historical count (do not decrement) to avoid complexity/gas;
            // if you want to decrement, uncomment below — note: iterating users costly.
            // _isUser[msg.sender] = false;
            // totalUsers -= 1;
        }

        require(stableToken.transfer(msg.sender, net), "Transfer failed");
        if (fee > 0) {
            // keep fee in contract (or send to admin treasury in future)
        }

        emit Withdrawn(msg.sender, net, fee);
    }

    /// @notice partial withdraw by percentage (1-100)
    function partialWithdraw(uint256 percentage) external whenNotPaused {
        require(percentage > 0 && percentage <= 100, "Invalid percent");
        uint256 userBal = balances[msg.sender];
        require(userBal > 0, "No balance");

        uint256 amount = (userBal * percentage) / 100;
        // call withdraw (nonReentrant prevents external reentry)
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
        require(users.length == amounts.length, "Array length mismatch");
        uint256 len = users.length;

        for (uint256 i = 0; i < len; ) {
            address u = users[i];
            uint256 amt = amounts[i];
            require(amt >= minimumDeposit, "Amount below minimum");

            require(stableToken.transferFrom(msg.sender, address(this), amt), "TransferFrom failed");

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
        uint256 averageBalance
    ) {
        contractBalance = stableToken.balanceOf(address(this));
        _totalUsers = totalUsers;
        averageBalance = 0;
        if (_totalUsers > 0) {
            // average of recorded totalDeposits (note: could use contractBalance as well)
            averageBalance = totalDeposits / _totalUsers;
        }
        return (_totalUsers, contractBalance, averageBalance);
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
        require(newAdmin != address(0), "Invalid address");
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
        require(newFee <= 1000, "Fee > 10%");
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

    /// @notice rebalance check (no automatic external calls, just report)
    function rebalance() external onlyAdmin {
        uint256 contractBalance = stableToken.balanceOf(address(this));
        // implement any reconciliation here (currently only emits)
        emit Rebalanced(totalDeposits, contractBalance);
    }

    /// @notice emergency withdraw to admin — only allowed when paused
    function emergencyWithdraw(uint256 amount) external onlyAdmin nonReentrant {
        require(paused, "Contract must be paused");
        uint256 contractBal = stableToken.balanceOf(address(this));
        require(amount <= contractBal, "Amount > contract balance");
        require(stableToken.transfer(admin, amount), "Emergency transfer failed");
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
}
