// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LoanManager {
    uint256 public constant COLLATERAL_RATIO = 50; // 50% LTV ratio
    IERC20 public immutable stable_token;

    struct Loan {
        address borrower;
        uint256 amount;
        uint256 dueDate;
        uint256 interestRate; // In basis points (1% = 100)
        bool active;
    }

    mapping(bytes32 => Loan) public loans;

    event LoanRequested(bytes32 loanId, address borrower, uint256 amount);
    event LoanRepaid(bytes32 loanId, address borrower);
    event CollateralReceived(bytes32 loanId, address borrower, uint256 amount);

    constructor(
        address _stable_token_loan
    ) {
        stable_token = IERC20(_stable_token_loan);
    }

    function requestLoan(
        uint collateralValue, // Value in usd
        uint256 amount, // amount in usdc
        uint256 duration // duration in days
    ) external {
        require(amount > 0, "Amount must be greater than 0");
        require(duration > 0, "Duration must be greater than 0");
        uint maxLoanAmount = (collateralValue * COLLATERAL_RATIO) / 100;
        require(maxLoanAmount >= amount, "Your loant amount cant be greater than your collateral");

         // Calculate loan ID
        bytes32 loanId = keccak256(
            abi.encodePacked(
                msg.sender,
                collateralValue,
                amount,
                block.timestamp
            )
        );

        // Create loan
        loans[loanId] = Loan({
            borrower: msg.sender,
            amount: amount,
            dueDate: block.timestamp + (duration * 1 days),
            interestRate: 500, // 5% fixed interest rate
            active: true
        });

        stable_token.transfer(msg.sender, amount);
    }

    function repayLoan(bytes32 loanId) external payable {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan not active");
        require(msg.sender == loan.borrower, "Not the borrower");

        // Calculate repayment amount with interest
        uint256 interest = (loan.amount * loan.interestRate * 
            (block.timestamp - (loan.dueDate - 30 days))) / (10000 * 365 days);
        uint256 totalRepayment = loan.amount + interest;
        
        require(msg.value >= totalRepayment, "Insufficient repayment amount");

        // Mark loan as inactive
        loan.active = false;

        // Send message to Starknet to release collateral
        bytes memory message = abi.encodeWithSignature(
            "releaseCollateral(bytes32)",
            loanId
        );

        emit LoanRepaid(loanId, msg.sender);

        // Return excess payment if any
        if (msg.value > totalRepayment) {
            (bool sent, ) = msg.sender.call{value: msg.value - totalRepayment}("");
            require(sent, "Failed to return excess payment");
        }
    }

    // View function to get loan details
    function getLoanDetails(bytes32 loanId) external view returns (
        address borrower,
        uint256 amount,
        uint256 dueDate,
        uint256 interestRate,
        bool active
    ) {
        Loan storage loan = loans[loanId];
        return (
            loan.borrower,
            loan.amount,
            loan.dueDate,
            loan.interestRate,
            loan.active
        );
    }

    // Function to calculate current repayment amount
    function getRepaymentAmount(bytes32 loanId) external view returns (uint256) {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan not active");
        
        uint256 interest = (loan.amount * loan.interestRate * 
            (block.timestamp - (loan.dueDate - 30 days))) / (10000 * 365 days);
        return loan.amount + interest;
    }
  
} 