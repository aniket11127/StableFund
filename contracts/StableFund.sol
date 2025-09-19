// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

contract StableFund {
    address public admin;
    IERC20 public stableToken;
    uint256 public totalDeposits;

    mapping(address => uint256) public balances;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Rebalanced(uint256 newTotal);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address tokenAddress) {
        admin = msg.sender;
        stableToken = IERC20(tokenAddress); // Initialize ERC20 token interface
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");
        require(
            stableToken.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        balances[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        totalDeposits -= amount;
        require(
            stableToken.transfer(msg.sender, amount),
            "Transfer failed"
        );
        emit Withdrawn(msg.sender, amount);
    }

    function rebalance() external onlyAdmin {
        // Placeholder for complex rebalancing logic
        emit Rebalanced(totalDeposits);
    }
}