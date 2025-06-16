use starknet::ContractAddress;
use alexandria_bytes::{Bytes, BytesTrait};
use hyperlane_starknet::interfaces::IMailboxDispatcher;
use hyperlane_starknet::libs::message::MessageTrait;
use core::byte_array::ByteArrayTrait;
use core::traits::Into;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
trait IVesu<TContractState> {
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
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
    use super::{IBtcVault, IERC20Dispatcher, IERC20DispatcherTrait, IVesuDispatcher, IVesuDispatcherTrait};
    use core::array::ArrayTrait;
    use starknet::contract_address::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{get_caller_address, get_contract_address};
    use core::byte_array::ByteArrayTrait;
    use core::traits::Into;

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
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        mailbox_address: ContractAddress,
        arbitrum_domain: u32,
        loan_manager_address: u256
    ) {
        self.owner.write(owner);
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
            self.total_deposits.write(self.total_deposits.read() + amount);
            let btc_address = self.get_btc_address();
            let vesu_address = self.get_vesu_address();
            let btc_contract = IERC20Dispatcher::new(btc_address);
            let vesu_contract = IVesuDispatcher::new(vesu_address);
            btc_contract.transfer_from(get_caller_address(), get_contract_address(), amount);
            self.user_deposits.write(get_caller_address(), amount);
            vesu_contract.deposit(amount, get_contract_address());

            // Approve VESU contract to spend tokens
            assert(
                btc_contract.approve(vesu_address, amount),
                'Approval failed'
            );

            // Deposit assets into VESU protocol
            let shares = vesu_contract.deposit(amount, get_contract_address());

            // Send message to Arbitrum LoanManager
            let mailbox = IMailboxDispatcher::new(self.mailbox_address.read());
            let mut message_body = BytesTrait::new_empty();
            let amount_bytes: Bytes = amount.into();
            let caller_bytes: Bytes = get_caller_address().into();
            ByteArrayTrait::append(ref message_body, amount_bytes);
            ByteArrayTrait::append(ref message_body, caller_bytes);

            mailbox.dispatch(
                self.arbitrum_domain.read(),
                self.loan_manager_address.read(),
                message_body,
                0, // No fee for now
                Option::None(()),
                Option::None(())
            );
        }

        fn withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'Only owner can withdraw');
            let btc_address = self.get_btc_address();
            let vesu_address = self.get_vesu_address();
            let btc_contract = IERC20Dispatcher::new(btc_address);
            let vesu_contract = IVesuDispatcher::new(vesu_address);
            let shares = self.user_deposits.read(get_caller_address());
            self.total_withdrawals.write(self.total_withdrawals.read() + amount);
            self.user_deposits.write(get_caller_address(), 0);
            vesu_contract.withdraw(shares, get_caller_address());
            btc_contract.transfer(get_caller_address(), amount);
        }

        fn get_total_deposits(self: @ContractState) -> u256 {
            self.total_deposits.read()
        }

        fn get_total_withdrawals(self: @ContractState) -> u256 {
            self.total_withdrawals.read()
        }
    }
}