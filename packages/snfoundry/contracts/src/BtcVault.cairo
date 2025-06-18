use starknet::ContractAddress;
// use alexandria_bytes::{Bytes, BytesTrait};
// use hyperlane_starknet::interfaces::{IMailboxDispatcher, IMessageRecipient};
// use hyperlane_starknet::libs::message::MessageTrait;
use core::byte_array::ByteArrayTrait;
use core::traits::Into;
use starknet::get_caller_address;
use starknet::get_contract_address;
use starknet::call_contract_syscall;
use core::result::ResultTrait;
use core::option::OptionTrait;
use openzeppelin::token::erc20::interface::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};

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

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
trait IVault<TContractState> {
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
}

#[starknet::contract]
mod BtcVault {
    use super::{IBtcVault, IERC20, IERC20Dispatcher, IERC20DispatcherTrait, IVault};
    use core::array::ArrayTrait;
    use starknet::contract_address::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{get_caller_address, get_contract_address};
    use core::byte_array::ByteArrayTrait;
    use core::traits::Into;

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct IVesuDispatcher {
        contract_address: ContractAddress,
    }

    #[generate_trait]
    impl IVesuDispatcherImpl of IVesuDispatcherImpl {
        fn new(contract_address: ContractAddress) -> IVesuDispatcher {
            IVesuDispatcher { contract_address }
        }

        fn deposit(self: IVesuDispatcher, assets: u256, receiver: ContractAddress) -> u256 {
            let mut calldata = ArrayTrait::new();
            calldata.append(assets.into());
            calldata.append(receiver.into());
            let ret_data = starknet::call_contract_syscall(
                self.contract_address,
                selector!("deposit"),
                calldata.span()
            ).unwrap();
            starknet::SyscallResult::unwrap(ret_data)
        }

        fn withdraw(self: IVesuDispatcher, shares: u256, receiver: ContractAddress) -> u256 {
            let mut calldata = ArrayTrait::new();
            calldata.append(shares.into());
            calldata.append(receiver.into());
            let ret_data = starknet::call_contract_syscall(
                self.contract_address,
                selector!("withdraw"),
                calldata.span()
            ).unwrap();
            starknet::SyscallResult::unwrap(ret_data)
        }
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
        LoanRequested: LoanRequested,
        LoanRepaid: LoanRepaid
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        user: ContractAddress,
        amount: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        user: ContractAddress,
        amount: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRequested {
        user: ContractAddress,
        amount: u256,
        collateral_amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRepaid {
        user: ContractAddress,
        amount: u256
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
        btc_token: ContractAddress,
        vault: ContractAddress,
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
        btc_token: ContractAddress,
        vault: ContractAddress,
    ) {
        self.owner.write(owner);
        self.btc_address.write(btc_address);
        self.vesu_address.write(vesu_address);
        self.mailbox_address.write(mailbox_address);
        self.arbitrum_domain.write(arbitrum_domain);
        self.loan_manager_address.write(loan_manager_address);
        self.btc_token.write(btc_token);
        self.vault.write(vault);
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
            let caller = get_caller_address();
            let btc_token = self.btc_token.read();
            let vault = self.vault.read();
            let contract_address = get_contract_address();

            // Transfer BTC from user to this contract
            assert!(
                IERC20::transfer_from(btc_token, caller, contract_address, amount),
                'Transfer failed'
            );

            // Approve vault to spend tokens
            assert!(
                IERC20::approve(btc_token, vault, amount),
                'Approval failed'
            );

            // Deposit into the vault
            let _shares = IVault::deposit(vault, amount, contract_address);

            // Update state
            self.total_deposits.write(self.total_deposits.read() + amount);
            self.user_deposits.write(caller, self.user_deposits.read(caller) + amount);
            self.user_shares.write(caller, self.user_shares.read(caller) + _shares);

            // Calculate loan amount (50% of collateral)
            let loan_amount = amount / 2;

            // Emit events
            self.emit(Deposit { user: caller, amount: amount, shares: _shares });
            self.emit(LoanRequested { user: caller, amount: loan_amount, collateral_amount: amount });
        }

        fn withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            assert(amount > 0, 'Amount must be greater than 0');
            assert(self.user_deposits.read(caller) >= amount, 'Insufficient balance');

            let btc_address = self.get_btc_address();
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
}