use alexandria_bytes::{Bytes, BytesTrait};
use core::byte_array::{ByteArray, ByteArrayTrait};
use contracts::interfaces::{IMailboxDispatcher, IMessageRecipient, IMailboxDispatcherTrait};
use contracts::libs::message::MessageTrait;
use core::traits::Into;
use starknet::{ContractAddress, get_caller_address, get_contract_address};

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
trait IVesu<TContractState> {
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn withdraw(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
}

#[starknet::interface]
pub trait IBtcVault<T> {
    // Deposit function
    fn depositVault(ref self: T, amount: u256);

    // Withdraw function
    fn withdraw(ref self: T, amount: u256);

    // Getter functions
    fn get_total_deposits(self: @T) -> u256;
    fn get_total_withdrawals(self: @T) -> u256;
    fn get_btc_address(self: @T) -> ContractAddress;
    fn get_vesu_address(self: @T) -> ContractAddress;
    fn get_mailbox_address(self: @T) -> ContractAddress;
    fn get_arbitrum_domain(self: @T) -> u32;
    fn get_loan_manager_address(self: @T) -> u256;
}

#[starknet::contract]
mod BtcVault {
    use core::array::ArrayTrait;
    use core::byte_array::{ByteArray, ByteArrayTrait};
    use core::traits::Into;
    use starknet::contract_address::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{get_caller_address, get_contract_address};
    use super::{
        IBtcVault, IERC20Dispatcher, IERC20DispatcherTrait, IMessageRecipient, IVesuDispatcher,
        IVesuDispatcherTrait, IMailboxDispatcher, IMailboxDispatcherTrait, Bytes, BytesTrait
    };

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
        LoanRequested: LoanRequested,
        LoanRepaid: LoanRepaid,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        user: ContractAddress,
        amount: u256,
        shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        user: ContractAddress,
        amount: u256,
        shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRequested {
        user: ContractAddress,
        amount: u256,
        collateral_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRepaid {
        user: ContractAddress,
        amount: u256,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        total_deposits: u256,
        total_withdrawals: u256,
        btc_address: ContractAddress,
        vesu_address: ContractAddress,
        mailbox_address: ContractAddress,
        arbitrum_domain: u32,
        loan_manager_address: u256,
        user_deposits: Map<ContractAddress, u256>,
        user_shares: Map<ContractAddress, u256>,
        active_loans: Map<ContractAddress, u256>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        btc_address: ContractAddress,
        vesu_address: ContractAddress,
        mailbox_address: ContractAddress,
        arbitrum_domain: u32,
        loan_manager_address: u256,
    ) {
        self.owner.write(owner);
        self.btc_address.write(btc_address);
        self.vesu_address.write(vesu_address);
        self.mailbox_address.write(mailbox_address);
        self.arbitrum_domain.write(arbitrum_domain);
        self.loan_manager_address.write(loan_manager_address);
    }

    #[abi(embed_v0)]
    impl BtcVaultImpl of IBtcVault<ContractState> {
        fn get_vesu_address(self: @ContractState) -> ContractAddress {
            self.vesu_address.read()
        }

        fn get_btc_address(self: @ContractState) -> ContractAddress {
            self.btc_address.read()
        }

        fn get_mailbox_address(self: @ContractState) -> ContractAddress {
            self.mailbox_address.read()
        }

        fn get_arbitrum_domain(self: @ContractState) -> u32 {
            self.arbitrum_domain.read()
        }

        fn get_loan_manager_address(self: @ContractState) -> u256 {
            self.loan_manager_address.read()
        }

        fn depositVault(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'Amount must be greater than 0');

            let caller = get_caller_address();
            let btc_address = self.get_btc_address();
            let vesu_address = self.get_vesu_address();

            // Transfer BTC from user
            let btc_contract = IERC20Dispatcher { contract_address: btc_address };
            assert(
                btc_contract.transfer_from(caller, get_contract_address(), amount),
                'Transfer failed',
            );

            // Approve VESU contract to spend tokens
            assert(btc_contract.approve(vesu_address, amount), 'Approval failed');

            // Deposit assets into VESU protocol
            let vesu_contract = IVesuDispatcher { contract_address: vesu_address };
            let shares = vesu_contract.deposit(amount, get_contract_address());

            // Update state
            self.total_deposits.write(self.total_deposits.read() + amount);
            self.user_deposits.write(caller, self.user_deposits.read(caller) + amount);
            self.user_shares.write(caller, self.user_shares.read(caller) + shares);

            // Calculate loan amount (50% of collateral)
            let loan_amount = amount / 2;

            // Send message to Arbitrum LoanManager
            let mailbox = IMailboxDispatcher { contract_address: self.mailbox_address.read() };
            let mut message_body = BytesTrait::new_empty();

            // Hardcoded values for demo
            message_body.append_address(caller);
            message_body.append_u256(1000); // Fixed loan amount
            message_body.append_u256(2000); // Fixed collateral amount

            // Dispatch message
            IMailboxDispatcherTrait::dispatch(
                mailbox,
                self.arbitrum_domain.read(),
                self.loan_manager_address.read(),
                message_body,
                0, // No fee for now
                Option::None(()),
                Option::None(()),
            );

            // Emit events
            self.emit(Deposit { user: caller, amount: amount, shares: shares });
            self.emit(
                LoanRequested { user: caller, amount: loan_amount, collateral_amount: amount },
            );
        }

        fn withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(amount > 0, 'Amount must be greater than 0');
            assert(self.user_deposits.read(caller) >= amount, 'Insufficient balance');

            let vesu_address = self.get_vesu_address();
            let shares = self.user_shares.read(caller);

            // Withdraw from VESU
            let vesu_contract = IVesuDispatcher { contract_address: vesu_address };
            let withdrawn_amount = vesu_contract.withdraw(shares, caller);

            // Update state
            self.total_withdrawals.write(self.total_withdrawals.read() + amount);
            self.user_deposits.write(caller, self.user_deposits.read(caller) - amount);
            self.user_shares.write(caller, 0);

            // Emit event
            self.emit(Withdraw { user: caller, amount: withdrawn_amount, shares: shares });
        }

        fn get_total_deposits(self: @ContractState) -> u256 {
            self.total_deposits.read()
        }

        fn get_total_withdrawals(self: @ContractState) -> u256 {
            self.total_withdrawals.read()
        }
    }

    #[abi(embed_v0)]
    impl IMessageRecipientImpl of IMessageRecipient<ContractState> {
        fn get_origin(self: @ContractState) -> u32 {
            self.arbitrum_domain.read()
        }

        fn get_sender(self: @ContractState) -> u256 {
            self.loan_manager_address.read()
        }

        fn get_message(self: @ContractState) -> Bytes {
            BytesTrait::new_empty()
        }

        fn handle(ref self: ContractState, _origin: u32, _sender: u256, _message: Bytes) {
            // Verify origin domain
            assert(_origin == self.arbitrum_domain.read(), 'Invalid origin domain');

            // Verify sender
            assert(_sender == self.loan_manager_address.read(), 'Invalid sender');

            // Parse message body
            let mut body_data = _message.data();
            let mut offset = 0;

            // Extract loan ID and status
            let loan_id = body_data.at(offset);
            offset += 1;
            let status = body_data.at(offset);

            // Handle loan status update
            // Mock function to check if loan is repaid
            let is_loan_repaid = false; // For now, we'll assume loan is not repaid
            if is_loan_repaid {
                let caller = get_caller_address();
                self.emit(LoanRepaid { user: caller, amount: self.active_loans.read(caller) });
                self.active_loans.write(caller, 0);
            }
        }
    }
}
