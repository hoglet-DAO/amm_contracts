
module spike_amm::coin_wrapper {
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::supra_account;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::event;

    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::string_utils;
    use aptos_std::type_info;
    use std::string::{Self, String};
    use std::option;
    use std::signer;
    use std::error;
    use spike_amm::package_manager;
    use spike_amm::amm_controller;

    friend spike_amm::amm_router;
    friend spike_amm::router_stake;
    friend spike_amm::amm_factory;
    friend spike_amm::flash_loan_router; 

    const COIN_WRAPPER_NAME: vector<u8> = b"COIN_YEET_FUNGIBLE";

    const ERROR_INSUFFICIENT_AMOUNT: u64 = 901;
    const ERROR_INVALID_REPAYMENT: u64 = 902;
    const ERROR_NOT_ADMIN: u64 = 903;
    const FLASH_LOAN_FEE_BPS: u64 = 5;

    struct FungibleAssetData has store {
        burn_ref: BurnRef,
        metadata: Object<Metadata>,
        mint_ref: MintRef,
    }

    struct WrapperAccount has key {

        signer_cap: SignerCapability,
        coin_to_fungible_asset: SmartTable<String, FungibleAssetData>,
        fungible_asset_to_coin: SmartTable<Object<Metadata>, String>,
    }

    struct FlashLoanReceipt<phantom CoinType> {
        amount: u64,
        fee: u64
    }

    #[event]
    struct FlashLoanEvent has drop, store {
        amount: u64,
        fee_amount: u64,
        coin_type: String
    }

    fun init_module(swap_signer: &signer) acquires WrapperAccount {
        if (is_initialized()) {
            return
        };

        let (coin_wrapper_signer, signer_cap) = account::create_resource_account(swap_signer, COIN_WRAPPER_NAME);
        package_manager::add_address(string::utf8(COIN_WRAPPER_NAME), signer::address_of(&coin_wrapper_signer));
        move_to(&coin_wrapper_signer, WrapperAccount {
            signer_cap,
            coin_to_fungible_asset: smart_table::new(),
            fungible_asset_to_coin: smart_table::new(),
        });
        create_fungible_asset<SupraCoin>();
    }

    fun get_wrapper_by_name_internal(coin_type_name: String): option::Option<Object<Metadata>> acquires WrapperAccount {
        let coin_to_fa = &wrapper_account().coin_to_fungible_asset;
        if (smart_table::contains(coin_to_fa, coin_type_name)) {
            let data = smart_table::borrow(coin_to_fa, coin_type_name);
            option::some(data.metadata)
        } else {
            option::none()
        }
    }

    #[view]
    public fun view_wrapper_by_components(
        account_address: address, 
        module_name: vector<u8>, 
        struct_name: vector<u8>
    ): option::Option<Object<Metadata>> acquires WrapperAccount {
        let coin_type_name = to_short_hex_string(account_address); 
        
        string::append(&mut coin_type_name, string::utf8(b"::"));
        string::append(&mut coin_type_name, string::utf8(module_name));
        string::append(&mut coin_type_name, string::utf8(b"::"));
        string::append(&mut coin_type_name, string::utf8(struct_name));

        get_wrapper_by_name_internal(coin_type_name)
    }

    #[view]
    public fun is_initialized(): bool {
        package_manager::address_exists(string::utf8(COIN_WRAPPER_NAME))
    }

    #[view]
    public fun wrapper_address(): address {
        package_manager::get_address(string::utf8(COIN_WRAPPER_NAME))
    }

    #[view]
    public fun is_supported<CoinType>(): bool acquires WrapperAccount {
        let coin_type = type_info::type_name<CoinType>();
        smart_table::contains(&wrapper_account().coin_to_fungible_asset, coin_type)
    }

    #[view]
    public fun is_wrapper(metadata: Object<Metadata>): bool acquires WrapperAccount {
        smart_table::contains(&wrapper_account().fungible_asset_to_coin, metadata)
    }

    #[view]
    public fun get_coin_type(metadata: Object<Metadata>): String acquires WrapperAccount {
        *smart_table::borrow(&wrapper_account().fungible_asset_to_coin, metadata)
    }

    #[view]
    public fun get_wrapper<CoinType>(): Object<Metadata> acquires WrapperAccount {
        fungible_asset_data<CoinType>().metadata
    }

    #[view]
    public fun get_original(fungible_asset: Object<Metadata>): String acquires WrapperAccount {
        if (is_wrapper(fungible_asset)) {
            get_coin_type(fungible_asset)
        } else {
            format_fungible_asset(fungible_asset)
        }
    }

    #[view]
    public fun format_fungible_asset(fungible_asset: Object<Metadata>): String {
        let fa_address = object::object_address(&fungible_asset);
        let fa_address_str = string_utils::to_string_with_canonical_addresses(&fa_address);
        string::sub_string(&fa_address_str, 1, string::length(&fa_address_str))
    }

    #[view]
    public fun get_balance<CoinType>(): u64 {
        coin::balance<CoinType>(wrapper_address())
    }

    public(friend) fun wrap<CoinType>(coins: Coin<CoinType>): FungibleAsset acquires WrapperAccount {
        create_fungible_asset<CoinType>();

        let amount = coin::value(&coins);
        supra_account::deposit_coins(wrapper_address(), coins);
        let mint_ref = &fungible_asset_data<CoinType>().mint_ref;
        fungible_asset::mint(mint_ref, amount)
    }

    public(friend) fun unwrap<CoinType>(fa: FungibleAsset): Coin<CoinType> acquires WrapperAccount {
        let amount = fungible_asset::amount(&fa);
        let burn_ref = &fungible_asset_data<CoinType>().burn_ref;
        fungible_asset::burn(burn_ref, fa);
        let wrapper_signer = &account::create_signer_with_capability(&wrapper_account().signer_cap);
        coin::withdraw(wrapper_signer, amount)
    }

    public(friend) fun create_fungible_asset<CoinType>(): Object<Metadata> acquires WrapperAccount {
        let coin_type = type_info::type_name<CoinType>();
        let wrapper_account = mut_wrapper_account();
        let coin_to_fungible_asset = &mut wrapper_account.coin_to_fungible_asset;
        let wrapper_signer = &account::create_signer_with_capability(&wrapper_account.signer_cap);
        if (!smart_table::contains(coin_to_fungible_asset, coin_type)) {
            let metadata_constructor_ref = &object::create_named_object(wrapper_signer, *string::bytes(&coin_type));
            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                metadata_constructor_ref,
                option::none(),
                coin::name<CoinType>(),
                coin::symbol<CoinType>(),
                coin::decimals<CoinType>(),
                string::utf8(b""),
                string::utf8(b""),
            );

            let mint_ref = fungible_asset::generate_mint_ref(metadata_constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(metadata_constructor_ref);
            let metadata = object::object_from_constructor_ref<Metadata>(metadata_constructor_ref);
            smart_table::add(coin_to_fungible_asset, coin_type, FungibleAssetData {
                metadata,
                mint_ref,
                burn_ref,
            });
            smart_table::add(&mut wrapper_account.fungible_asset_to_coin, metadata, coin_type);
        };
        smart_table::borrow(coin_to_fungible_asset, coin_type).metadata
    }

    public(friend) fun get_wrapper_for_type_info(info: type_info::TypeInfo): option::Option<Object<Metadata>> acquires WrapperAccount {
        let coin_type_name = to_short_hex_string(type_info::account_address(&info));

        string::append(&mut coin_type_name, string::utf8(b"::"));
        string::append(&mut coin_type_name, string::utf8(type_info::module_name(&info)));
        string::append(&mut coin_type_name, string::utf8(b"::"));
        string::append(&mut coin_type_name, string::utf8(type_info::struct_name(&info)));

        get_wrapper_by_name_internal(coin_type_name)
    }

    public fun flash_loan<CoinType>(
        amount: u64
    ): (Coin<CoinType>, FlashLoanReceipt<CoinType>) acquires WrapperAccount {
        let wrapper_acc = wrapper_account();
        let wrapper_signer = &account::create_signer_with_capability(&wrapper_acc.signer_cap);
        
        assert!(coin::balance<CoinType>(wrapper_address()) >= amount, error::invalid_argument(ERROR_INSUFFICIENT_AMOUNT));

        let loan_coins = coin::withdraw<CoinType>(wrapper_signer, amount);
        let bps = amm_controller::get_flash_loan_fee_bps();
        let fee = (amount * bps) / 10000;

        let receipt = FlashLoanReceipt { amount, fee };

        event::emit(FlashLoanEvent {
            amount,
            fee_amount: fee,
            coin_type: type_info::type_name<CoinType>()
        });

        (loan_coins, receipt)
    }

    public fun repay_flash_loan<CoinType>(
        repayment: Coin<CoinType>,
        receipt: FlashLoanReceipt<CoinType>
    ) {
        let FlashLoanReceipt { amount, fee } = receipt;

        let repayment_amount = coin::value(&repayment);
        assert!(repayment_amount >= amount + fee, error::invalid_argument(ERROR_INVALID_REPAYMENT));

        supra_account::deposit_coins(wrapper_address(), repayment);
    }

    public entry fun collect_accumulated_fees<CoinType>(
        admin: &signer,
        amount: u64,
        to: address
    ) acquires WrapperAccount {
        assert!(signer::address_of(admin) == amm_controller::get_admin(), error::permission_denied(ERROR_NOT_ADMIN));

        let wrapper_acc = wrapper_account();
        let wrapper_signer = &account::create_signer_with_capability(&wrapper_acc.signer_cap);
        let total_real_balance = coin::balance<CoinType>(wrapper_address());
        
        let fa_data = fungible_asset_data<CoinType>();
        let total_supply_fa = option::destroy_some(fungible_asset::supply(fa_data.metadata));

        let user_collateral = (total_supply_fa as u64);
        let available_fees = if (total_real_balance > user_collateral) {
            total_real_balance - user_collateral
        } else {
            0
        };

        assert!(amount <= available_fees, error::invalid_argument(ERROR_INSUFFICIENT_AMOUNT));

        let coins = coin::withdraw<CoinType>(wrapper_signer, amount);
        coin::deposit(to, coins);
    }

    inline fun fungible_asset_data<CoinType>(): &FungibleAssetData acquires WrapperAccount {
        let coin_type = type_info::type_name<CoinType>();
        smart_table::borrow(&wrapper_account().coin_to_fungible_asset, coin_type)
    }

    inline fun wrapper_account(): &WrapperAccount acquires WrapperAccount {
        borrow_global<WrapperAccount>(wrapper_address())
    }

    inline fun mut_wrapper_account(): &mut WrapperAccount acquires WrapperAccount {
        borrow_global_mut<WrapperAccount>(wrapper_address())
    }

    fun to_short_hex_string(addr: address): String {
        let bytes = supra_framework::bcs::to_bytes(&addr);
        let res = string::utf8(b"0x");
        let i = 0;

        while (i < 31 && *std::vector::borrow(&bytes, i) == 0) {
            i = i + 1;
        };

        let first_byte = *std::vector::borrow(&bytes, i);
        let high = first_byte >> 4;
        let low = first_byte & 0x0f;

        if (high > 0) string::append(&mut res, num_to_hex(high));
        string::append(&mut res, num_to_hex(low));
        i = i + 1;

        while (i < 32) {
            let b = *std::vector::borrow(&bytes, i);
            string::append(&mut res, num_to_hex(b >> 4));
            string::append(&mut res, num_to_hex(b & 0x0f));
            i = i + 1;
        };
        res
    }

    fun num_to_hex(num: u8): String {
        if (num < 10) string::utf8(vector[num + 48])
        else string::utf8(vector[num + 87])
    }
}