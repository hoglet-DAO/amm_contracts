module spike_amm::flash_loan_router {
    use supra_framework::coin::{Self, Coin}; 
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::object::{Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::account::{Self, SignerCapability}; 
    use std::signer;
    use std::error;
    use std::option;

    use spike_amm::amm_pair;
    use spike_amm::coin_wrapper;
    use spike_amm::amm_controller;

    // --- STRUCTS ---

    const ERROR_NOT_INITIALIZED: u64 = 800;
    const ERROR_NOT_ADMIN: u64 = 801;
    const ERROR_ALREADY_INITIALIZED: u64 = 802;
    const ERROR_METADATA_NOT_FOUND: u64 = 803; 

    // --- CONSTANTES ---
    const ROUTER_SEED: vector<u8> = b"SPIKE_ROUTER_SIGNER_V1"; 

    struct RouterCapability has key {
        signer_cap: SignerCapability
    }
    
    struct FlashLoanFromPoolAsCoinReceipt<phantom CoinType> {
        pair_receipt: amm_pair::FlashLoanReceipt,
        loan_amount: u64
    }

    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @spike_amm, error::permission_denied(ERROR_NOT_ADMIN));
        if (exists<RouterCapability>(admin_addr)) {
            abort error::already_exists(ERROR_ALREADY_INITIALIZED)
        };
        let (_router_signer, signer_cap) = account::create_resource_account(admin, ROUTER_SEED);
        move_to(admin, RouterCapability { signer_cap });
    }
    
    // ===================================================================
    // 1. "WHALE" SCENARIO: Withdrawal from Wrapper (Staking + AMM Liquidity)
    // Type: Coin Legacy / Native
    // =================================================================

    public fun borrow_from_vault<CoinType>(
        amount: u64
    ): (Coin<CoinType>, coin_wrapper::FlashLoanReceipt<CoinType>) {
        coin_wrapper::flash_loan<CoinType>(amount)
    }

    public fun repay_to_vault<CoinType>(
        payment: Coin<CoinType>,
        receipt: coin_wrapper::FlashLoanReceipt<CoinType>
    ) {
        coin_wrapper::repay_flash_loan(payment, receipt);
    }

    public fun borrow_from_pool_as_coin<CoinType>(
        pair: Object<amm_pair::Pair>,
        amount: u64
    ): (Coin<CoinType>, FlashLoanFromPoolAsCoinReceipt<CoinType>) acquires RouterCapability {
        
        let is_legacy = coin_wrapper::is_supported<CoinType>();
        let use_wrapper = false;
        let token_to_borrow: Object<Metadata>;

        // 1. Decide which token to borrow (Wrapper vs Native)
        if (is_legacy) {
            let wrapper_metadata = coin_wrapper::get_wrapper<CoinType>();
            // If the balance of the Wrapper in the pool is > 0, we assume it is a Wrapper Pool
            if (amm_pair::balance_of(pair, wrapper_metadata) > 0) {
                use_wrapper = true;
                token_to_borrow = wrapper_metadata;
            } else {
                token_to_borrow = get_smart_metadata_internal<CoinType>();
            }
        } else {
            token_to_borrow = get_smart_metadata_internal<CoinType>();
        };

        // 2. Execute Flash Loan
        let (loaned_fa, pair_receipt) = amm_pair::flash_loan(pair, token_to_borrow, amount);
        let native_coin: Coin<CoinType>;

        // 3. Convert to Coin
        if (use_wrapper) {
            native_coin = coin_wrapper::unwrap<CoinType>(loaned_fa);
        } else {
            let router_signer = get_router_signer();
            let router_addr = signer::address_of(&router_signer);
            if (!coin::is_account_registered<CoinType>(router_addr)) {
                coin::register<CoinType>(&router_signer);
            };
            primary_fungible_store::deposit(router_addr, loaned_fa);
            native_coin = coin::withdraw<CoinType>(&router_signer, amount);
        };
        
        // 4. Return Receipt (No new fields)
        let router_receipt = FlashLoanFromPoolAsCoinReceipt {
            pair_receipt,
            loan_amount: amount
        };

        (native_coin, router_receipt)
    }

    public fun repay_to_pool_as_coin<CoinType>(
        payment: Coin<CoinType>,
        receipt: FlashLoanFromPoolAsCoinReceipt<CoinType>,
        pair: Object<amm_pair::Pair>
    ) {
        let FlashLoanFromPoolAsCoinReceipt { pair_receipt, loan_amount: _ } = receipt;
        
        // 1. Re-evaluate: Should we pay with Wrapper or Native?
        // We use the same heuristic logic as in the borrow.
        let is_legacy = coin_wrapper::is_supported<CoinType>();
        let use_wrapper = false;

        if (is_legacy) {
            let wrapper_metadata = coin_wrapper::get_wrapper<CoinType>();
            // Check balance in the pair. 
            // If balance > 0, it is a Wrapper pool.
            // NOTE: If you emptied the pool 100% (balance=0), this will fail and assume Native.
            if (amm_pair::balance_of(pair, wrapper_metadata) > 0) {
                use_wrapper = true;
            };
        };

        let fa_payment: FungibleAsset;

        if (use_wrapper) {
            // PATH A: Wrap (Coin -> Wrapper FA)
            fa_payment = coin_wrapper::wrap<CoinType>(payment);
        } else {
            // PATH B: Standard (Coin -> Native FA)
            fa_payment = coin::coin_to_fungible_asset<CoinType>(payment);
        };

        // 2. Repay to the Pool
        amm_pair::repay_flash_loan(pair, fa_payment, pair_receipt);
    }


    // ===================================================================
    // 2. "POOL" SCENARIO: Withdrawal from AMM Pool
    // Type: Fungible Asset (FA)
    // =================================================================

    public fun borrow_fa_from_pool(
        pair: Object<amm_pair::Pair>,
        token: Object<Metadata>,
        amount: u64
    ): (FungibleAsset, amm_pair::FlashLoanReceipt) {
        amm_pair::flash_loan(pair, token, amount)
    }

    public fun repay_fa_to_pool(
        pair: Object<amm_pair::Pair>,
        payment: FungibleAsset,
        receipt: amm_pair::FlashLoanReceipt
    ) {
        amm_pair::repay_flash_loan(pair, payment, receipt);
    }

    public fun native_fa_to_coin<CoinType>(fa: FungibleAsset): Coin<CoinType> acquires RouterCapability {
        if (coin_wrapper::is_supported<CoinType>()) {
            let wrapper_meta = coin_wrapper::get_wrapper<CoinType>();
            // 2. If the FA is the Wrapper, we do Unwrap (Without touching CoinStore)
            if (fungible_asset::metadata_from_asset(&fa) == wrapper_meta) {
                return coin_wrapper::unwrap<CoinType>(fa)
            };
        };

        let paired_meta_opt = coin::paired_metadata<CoinType>();
        assert!(std::option::is_some(&paired_meta_opt), error::invalid_argument(ERROR_METADATA_NOT_FOUND));
        let paired_meta = std::option::extract(&mut paired_meta_opt);

        let input_meta = fungible_asset::asset_metadata(&fa);
        assert!(
            input_meta == paired_meta, 
            error::invalid_argument(ERROR_METADATA_NOT_FOUND)
        );

        let amount = fungible_asset::amount(&fa);
        let router_signer = get_router_signer();
        let router_addr = signer::address_of(&router_signer);

        if (!coin::is_account_registered<CoinType>(router_addr)) {
            coin::register<CoinType>(&router_signer);
        };

        primary_fungible_store::deposit(router_addr, fa);

        coin::withdraw<CoinType>(&router_signer, amount)
    }


    public fun coin_to_native_fa<CoinType>(c: Coin<CoinType>): FungibleAsset {
        coin::coin_to_fungible_asset<CoinType>(c)
    }

    public fun get_internal_metadata<CoinType>(): Object<Metadata> {
        coin_wrapper::get_wrapper<CoinType>()
    }

    fun get_smart_metadata_internal<CoinType>(): Object<Metadata> {
        let meta_opt = coin::paired_metadata<CoinType>();
        if (option::is_some(&meta_opt)) {
            option::destroy_some(meta_opt)
        } else {
             abort error::not_found(ERROR_METADATA_NOT_FOUND) 
        }
    }

    fun get_router_signer(): signer acquires RouterCapability {
        assert!(exists<RouterCapability>(@spike_amm), ERROR_NOT_INITIALIZED);
        let cap = &borrow_global<RouterCapability>(@spike_amm).signer_cap;
        account::create_signer_with_capability(cap)
    }

    // Returns where there is more liquidity for this coin.
    // Returns: 0 = None, 1 = Vault (Wrapper), 2 = Pool (FA)
    #[view]
    public fun check_best_liquidity_source<CoinType>(
        pair: Object<amm_pair::Pair>
    ): u8 {
        // 1. Check Vault (CoinWrapper)
        let vault_bal = if (coin_wrapper::is_supported<CoinType>()) {
            coin_wrapper::get_balance<CoinType>()
        } else {
            0
        };

        // If we have good liquidity in the Vault, we return 1 immediately.
        // (Adjust the threshold of 1000 as needed)
        if (vault_bal > 1000) {
            return 1
        };

        // 2. Check Pool (We try to see if the pool has the Wrapper or the Native)
        let native_meta = get_smart_metadata_internal<CoinType>();
        let pool_bal_native = amm_pair::balance_of(pair, native_meta);
        
        let pool_bal_wrapper = 0;
        if (coin_wrapper::is_supported<CoinType>()) {
            let wrapper_meta = coin_wrapper::get_wrapper<CoinType>();
            pool_bal_wrapper = amm_pair::balance_of(pair, wrapper_meta);
        };

        let max_pool_bal = if (pool_bal_wrapper > pool_bal_native) { pool_bal_wrapper } else { pool_bal_native };

        if (max_pool_bal > 0) {
            return 2 // Pool wins
        } else if (vault_bal > 0) {
            return 1 // Vault wins (in extremis)
        } else {
            0
        }
    }

    #[view]
    public fun expected_fee(amount: u64): u64 {
        let bps = amm_controller::get_flash_loan_fee_bps();
        (amount * bps) / 10000
    }

    #[view]
    public fun max_flash_loan_vault<CoinType>(): u64 {
        coin_wrapper::get_balance<CoinType>()
    }

    #[view]
    public fun max_flash_loan_pool(pair: Object<amm_pair::Pair>, token: Object<Metadata>): u64 {
        amm_pair::balance_of(pair, token)
    }

    #[view]
    public fun get_native_metadata<CoinType>(): Object<Metadata> {
        get_smart_metadata_internal<CoinType>()

    }

}