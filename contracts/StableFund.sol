// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract StableFund {
    address public admin;
    IERC20 public stableToken;
    uint256 public totalDeposits;
    uint256 public minimumDeposit = 100; // Default minimum deposit
    uint256 public withdrawalFee = 50; // Fee in basis points (0.5%)
    bool public paused = false;
    
    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => bool) public authorizedUsers;
    
    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event Rebalanced(uint256 newTotal);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event MinimumDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(bool paused);
    event UserAuthorized(address indexed user, bool authorized);
    event EmergencyWithdrawal(address indexed admin, uint256 amount);

    // Modifiers
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    modifier onlyAuthorizedOrAdmin() {
        require(msg.sender == admin || authorizedUsers[msg.sender], "Not authorized");
        _;
    }

    constructor(address tokenAddress) {
        admin = msg.sender;
        stableToken = IERC20(tokenAddress);
        authorizedUsers[msg.sender] = true; // Admin is authorized by default
    }

    // Enhanced deposit function
    function deposit(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        require(amount >= minimumDeposit, "Amount below minimum deposit");
        require(
            stableToken.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        
        balances[msg.sender] += amount;
        totalDeposits += amount;
        lastDepositTime[msg.sender] = block.timestamp;
        
        emit Deposited(msg.sender, amount);
    }

    // Enhanced withdraw function with fees
    function withdraw(uint256 amount) external whenNotPaused {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        require(amount > 0, "Amount must be greater than zero");
        
        uint256 fee = calculateWithdrawalFee(amount);
        uint256 netAmount = amount - fee;
        
        balances[msg.sender] -= amount;
        totalDeposits -= amount;
        
        require(
            stableToken.transfer(msg.sender, netAmount),
            "Transfer failed"
        );
        
        emit Withdrawn(msg.sender, netAmount, fee);
    }

    // Partial withdrawal function
    function partialWithdraw(uint256 percentage) external whenNotPaused {
        require(percentage > 0 && percentage <= 100, "Invalid percentage");
        
        uint256 userBalance = balances[msg.sender];
        require(userBalance > 0, "No balance to withdraw");
        
        uint256 amount = (userBalance * percentage) / 100;
        withdraw(amount);
    }

    // Get user information
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

    // Calculate withdrawal fee
    function calculateWithdrawalFee(uint256 amount) public view returns (uint256) {
        return (amount * withdrawalFee) / 10000; // Basis points calculation
    }

    // Get contract statistics
    function getContractStats() external view returns (
        uint256 totalUsers,
        uint256 contractBalance,
        uint256 averageBalance
    ) {
        contractBalance = stableToken.balanceOf(address(this));
        
        // Note: totalUsers would need to be tracked separately for gas efficiency
        // This is a simplified version
        if (totalDeposits > 0) {
            averageBalance = totalDeposits; // Simplified calculation
        }
        
        return (0, contractBalance, averageBalance); // totalUsers set to 0 for now
    }

    // Bulk operations for authorized users
    function bulkDeposit(address[] calldata users, uint256[] calldata amounts) 
        external 
        onlyAuthorizedOrAdmin 
        whenNotPaused 
    {
        require(users.length == amounts.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            require(amounts[i] >= minimumDeposit, "Amount below minimum");
            require(
                stableToken.transferFrom(msg.sender, address(this), amounts[i]),
                "Transfer failed"
            );
            
            balances[users[i]] += amounts[i];
            totalDeposits += amounts[i];
            lastDepositTime[users[i]] = block.timestamp;
            
            emit Deposited(users[i], amounts[i]);
        }
    }

    // Admin functions
    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin address");
        address oldAdmin = admin;
        admin = newAdmin;
        authorizedUsers[newAdmin] = true;
        emit AdminChanged(oldAdmin, newAdmin);
    }

    function setMinimumDeposit(uint256 newMinimum) external onlyAdmin {
        uint256 oldMinimum = minimumDeposit;
        minimumDeposit = newMinimum;
        emit MinimumDepositUpdated(oldMinimum, newMinimum);
    }

    function setWithdrawalFee(uint256 newFee) external onlyAdmin {
        require(newFee <= 1000, "Fee cannot exceed 10%"); // Max 10% fee
        uint256 oldFee = withdrawalFee;
        withdrawalFee = newFee;
        emit WithdrawalFeeUpdated(oldFee, newFee);
    }

    function pauseContract(bool _paused) external onlyAdmin {
        paused = _paused;
        emit ContractPaused(_paused);
    }

    function authorizeUser(address user, bool authorized) external onlyAdmin {
        authorizedUsers[user] = authorized;
        emit UserAuthorized(user, authorized);
    }

    // Enhanced rebalance function
    function rebalance() external onlyAdmin {
        uint256 contractBalance = stableToken.balanceOf(address(this));
        
        // Rebalancing logic would go here
        // This could involve:
        // - Checking if contract balance matches totalDeposits
        // - Adjusting for any discrepancies
        // - Reporting rebalance results
        
        emit Rebalanced(totalDeposits);
    }

    // Emergency functions
    function emergencyWithdraw(uint256 amount) external onlyAdmin {
        require(paused, "Contract must be paused for emergency withdrawal");
        require(
            stableToken.transfer(admin, amount),
            "Emergency withdrawal failed"
        );
        emit EmergencyWithdrawal(admin, amount);
    }

    // View functions
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

    // Function to check if contract is healthy (balance matches deposits)
    function isContractHealthy() external view returns (bool, uint256, uint256) {
        uint256 contractBalance = stableToken.balanceOf(address(this));
        bool healthy = contractBalance >= totalDeposits;
        return (healthy, contractBalance, totalDeposits);
    }
}
