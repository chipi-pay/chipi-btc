// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@hyperlane-xyz/core/interfaces/IMailbox.sol";
import "@hyperlane-xyz/core/interfaces/IInterchainSecurityModule.sol";
import "@hyperlane-xyz/core/interfaces/IMessageRecipient.sol";

contract LoanManager is IMessageRecipient {
    IMailbox public hyperlaneMailbox;
    uint32 public arbDomain;
    bytes32 public collateralManagerAddress;
    uint256 public constant COLLATERAL_RATIO = 50; // 50% LTV ratio

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
        address _hyperlaneMailbox,
        uint32 _arbDomain,
        address _collateralManager
    ) {
        hyperlaneMailbox = IMailbox(_hyperlaneMailbox);
        arbDomain = _arbDomain;
        collateralManagerAddress = bytes32(uint256(uint160(_collateralManager)));
    }

    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _message
    ) external override {
        require(msg.sender == address(hyperlaneMailbox), "Not from mailbox");
        require(_origin == arbDomain, "Not from Arbitrum");
        require(_sender == collateralManagerAddress, "Not from collateral manager");

        // Decode message
        (uint256 amount, address borrower) = abi.decode(_message, (uint256, address));
        
        // Calculate loan amount (50% of collateral value)
        uint256 loanAmount = (amount * COLLATERAL_RATIO) / 100;

        // Generate loan ID
        bytes32 loanId = keccak256(
            abi.encodePacked(
                borrower,
                amount,
                block.timestamp
            )
        );

        // Create loan
        loans[loanId] = Loan({
            borrower: borrower,
            amount: loanAmount,
            dueDate: block.timestamp + 30 days, // 30 days loan term
            interestRate: 500, // 5% fixed interest rate
            active: true
        });

        emit CollateralReceived(loanId, borrower, amount);
        emit LoanRequested(loanId, borrower, loanAmount);

        // Transfer loan amount to borrower
        (bool sent, ) = borrower.call{value: loanAmount}("");
        require(sent, "Failed to send loan amount");
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

        hyperlaneMailbox.dispatch(
            arbDomain,
            collateralManagerAddress,
            message
        );

        emit LoanRepaid(loanId, msg.sender);

        // Return excess payment if any
        if (msg.value > totalRepayment) {
            (bool sent, ) = msg.sender.call{value: msg.value - totalRepayment}("");
            require(sent, "Failed to return excess payment");
        }
    }

    // View function to get loan details
    function getLoan(bytes32 loanId) external view returns (
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

    receive() external payable {}
} 