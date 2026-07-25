module spike_amm::amm_router {
    use std::option;
    use std::signer;
    use std::vector;
    use std::error;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::supra_account;
    use supra_framework::coin;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use spike_amm::amm_factory;
    use spike_amm::amm_pair;
    use spike_amm::coin_wrapper;
    use razor_libs::utils;
    use razor_libs::sort;

    const ERROR_EXPIRED: u64 = 1;
    const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 2;
    const ERROR_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 3;
    const ERROR_EXCESSIVE_INPUT_AMOUNT: u64 = 4;
    const ERROR_INVALID_PATH: u64 = 5;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 6;
    const ERROR_INVALID_TOKEN_ORDER: u64 = 7;
    const ERROR_INVALID_AMOUNT: u64 = 8;
    const ERROR_INVALID_PATH_LENGTH: u64 = 9;
    const ERROR_IDENTICAL_TOKENS: u64 = 10;
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 11;
    const ERROR_INSUFFICIENT_A_AMOUNT: u64 = 12;
    const ERROR_INSUFFICIENT_B_AMOUNT: u64 = 13;
    const ERROR_INTERNAL_ERROR: u64 = 14;
    const ERROR_ZERO_AMOUNT: u64 = 15;
    const ERROR_BWSUP_AS_OUTPUT_NOT_ALLOWED: u64 = 16;
    const ERROR_TOKEN_B_MUST_BE_BWSUP: u64 = 17;
    const ERROR_USE_COIN_FUNCTION: u64 = 18;
    const ERROR_USE_BWSUP_INSTEAD: u64 = 19;
    const ERROR_INVALID_TOKEN_ADDRESS: u64 = 20;

    const WSUP: address = @0xa;
    const MIN_PATH_LENGTH: u64 = 2;

    fun get_canonical_address(addr: address): address {
        if (addr == WSUP) {
            return get_address_BWSUP()
        };
        
        if (object::object_exists<Metadata>(addr)) {
            let metadata = object::address_to_object<Metadata>(addr);
            if (coin_wrapper::is_wrapper(metadata)) {
                return addr
            };

            let paired_coin_opt = supra_framework::coin::paired_coin(metadata);
            if (option::is_some(&paired_coin_opt)) {
                let coin_info = option::destroy_some(paired_coin_opt);
                let my_wrapper_opt = coin_wrapper::get_wrapper_for_type_info(coin_info);
                if (option::is_some(&my_wrapper_opt)) {
                    return object::object_address(&option::destroy_some(my_wrapper_opt))
                };
            };
            return addr
        };
        abort error::invalid_argument(ERROR_INVALID_TOKEN_ADDRESS)
    }

    fun calc_optimal_coin_values(
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        amount_a_desired: u64,
        amount_b_desired: u64,
        amount_aMin: u64,
        amount_bMin: u64,
    ): (u64, u64) {
        assert!(
            amount_aMin <= amount_a_desired && amount_bMin <= amount_b_desired,
            error::invalid_argument(ERROR_INSUFFICIENT_AMOUNT)
        );
        
        let pair = amm_pair::liquidity_pool(token_a, token_b);
        let (reserve_a, reserve_b, _) = amm_pair::get_reserves(pair);

        if (!sort::is_sorted_two(token_a, token_b)) {
            (reserve_a, reserve_b) = (reserve_b, reserve_a)
        };

        if (reserve_a == 0 && reserve_b == 0) {
            (amount_a_desired, amount_b_desired)
        } else {
            let amount_b_optimal = utils::quote(amount_a_desired, reserve_a, reserve_b);
            if (amount_b_optimal <= amount_b_desired) {
                assert!(
                    amount_b_optimal >= amount_bMin,
                    error::invalid_argument(ERROR_INSUFFICIENT_B_AMOUNT)
                );
                (amount_a_desired, amount_b_optimal)
            } else {
                let amount_a_optimal = utils::quote(amount_b_desired, reserve_b, reserve_a);
                assert!(
                    amount_a_optimal <= amount_a_desired,
                    error::invalid_argument(ERROR_INTERNAL_ERROR)
                );
                assert!(
                    amount_a_optimal >= amount_aMin,
                    error::invalid_argument(ERROR_INSUFFICIENT_A_AMOUNT)
                );
                (amount_a_optimal, amount_b_desired)
            }
        }
    }

    fun ensure_path_does_not_start_with(
        path: &vector<address>,
        forbidden_address: address,
    ) {
        assert!(
            vector::length(path) >= MIN_PATH_LENGTH,
            error::invalid_argument(ERROR_INVALID_PATH_LENGTH)
        );

        assert!(
            *vector::borrow(path, 0) != forbidden_address,
            error::invalid_argument(ERROR_INVALID_PATH)
        );
    }

    fun ensure_path_does_not_end_with(
        path: &vector<address>,
        forbidden_address: address,
    ) {
        let len = vector::length(path);
        assert!(
            len >= MIN_PATH_LENGTH,
            error::invalid_argument(ERROR_INVALID_PATH_LENGTH)
        );
        assert!(
            *vector::borrow(path, len - 1) != forbidden_address,
            error::invalid_argument(ERROR_INVALID_PATH)
        );
    }

    fun validate_path_start(path: &vector<address>, expected: address) {
        assert!(
            vector::length(path) >= MIN_PATH_LENGTH,
            error::invalid_argument(ERROR_INVALID_PATH_LENGTH)
        );
        
        let actual_start = *vector::borrow(path, 0);
        let bwsup_addr = get_address_BWSUP();

        if (expected == bwsup_addr) {
            assert!(
                actual_start == bwsup_addr || actual_start == WSUP,
                error::invalid_argument(ERROR_INVALID_PATH)
            );
        } else {
            assert!(
                actual_start == expected,
                error::invalid_argument(ERROR_INVALID_PATH)
            );
        };
    }

    fun validate_path_end(path: &vector<address>, expected: address) {
        let len = vector::length(path);
        assert!(
            len >= MIN_PATH_LENGTH,
            error::invalid_argument(ERROR_INVALID_PATH_LENGTH)
        );

        let actual_last = *vector::borrow(path, len - 1);
        let bwsup_addr = get_address_BWSUP();

        if (expected == bwsup_addr) {
            assert!(
                actual_last == bwsup_addr || actual_last == WSUP,
                error::invalid_argument(ERROR_INVALID_PATH)
            );
        } else {
            assert!(
                actual_last == expected,
                error::invalid_argument(ERROR_INVALID_PATH)
            );
        }
    }
    
    fun assert_is_pure_native_fa(token_addr: address) {
        amm_factory::assert_is_pure_native_fa(token_addr);
    }

    fun normalize_path(path: vector<address>): vector<address> {
        let i = 0;
        let len = vector::length(&path);
        while (i < len) {
            let addr = vector::borrow_mut(&mut path, i);
            *addr = get_canonical_address(*addr);
            i = i + 1;
        };
        path
    }

    fun smart_inject_path_start<CoinType>(path: &mut vector<address>) {
        let coin_object = coin_wrapper::create_fungible_asset<CoinType>();
        let expected_start = object::object_address(&coin_object);
        if (vector::is_empty(path) || *vector::borrow(path, 0) != expected_start) {
            vector::insert(path, 0, expected_start);
        };
    }

    fun smart_inject_path_end<CoinType>(path: &mut vector<address>) {
        let coin_object = coin_wrapper::create_fungible_asset<CoinType>();
        let expected_end = object::object_address(&coin_object);
        let len = vector::length(path);
        if (len == 0 || *vector::borrow(path, len - 1) != expected_end) {
            vector::push_back(path, expected_end);
        };
    }
    
    fun smart_withdraw(sender: &signer, token_obj: Object<Metadata>, amount: u64): FungibleAsset {
        let sender_addr = signer::address_of(sender);
        let token_addr = object::object_address(&token_obj);
        let bwsup_addr = get_address_BWSUP();

        if (primary_fungible_store::balance(sender_addr, token_obj) >= amount) {
            primary_fungible_store::withdraw(sender, token_obj, amount)
        } 
        else if (token_addr == bwsup_addr) {
            let supra_coin = coin::withdraw<SupraCoin>(sender, amount);
            coin_wrapper::wrap<SupraCoin>(supra_coin)
        }
        else {
            primary_fungible_store::withdraw(sender, token_obj, amount)
        }
    }

    fun smart_deposit(to: address, asset: FungibleAsset) {
        let metadata = fungible_asset::asset_metadata(&asset);
        
        if (object::object_address(&metadata) == get_address_BWSUP()) {
            let supra_coin = coin_wrapper::unwrap<SupraCoin>(asset);
            supra_account::deposit_coins(to, supra_coin);
        } else {
            primary_fungible_store::deposit(to, asset);
        }
    }

    inline fun ensure(deadline: u64) {
        assert!(
            deadline >= timestamp::now_seconds(),
            error::invalid_argument(ERROR_EXPIRED)
        );
    }

    inline fun validate_amount(amount: u64) {
        assert!(
            amount > 0,
            error::invalid_argument(ERROR_INVALID_AMOUNT)
        );
    }

    inline fun validate_token_pair(tokenA: address, tokenB: address) {
        assert!(
            tokenA != tokenB,
            error::invalid_argument(ERROR_IDENTICAL_TOKENS)
        );
    }

    public entry fun wrap_coin<CoinType>(
        sender: &signer,
        amount: u64
    ) {
        let to = signer::address_of(sender);
        let coin = coin::withdraw<CoinType>(sender, amount);
        let fa = coin::coin_to_fungible_asset<CoinType>(coin);
        primary_fungible_store::deposit(to, fa);
    }

    public entry fun wrap_supra(
        sender: &signer,
        amount: u64,
    ) {
        let to = signer::address_of(sender);
        let coin = coin::withdraw<SupraCoin>(sender, amount);
        let fa = coin::coin_to_fungible_asset<SupraCoin>(coin);
        primary_fungible_store::deposit(to, fa);
    }

    fun wrap_beta<CoinType>(
        sender: &signer,
        to: address,
        amount: u64
    ) {
        let coin = coin::withdraw<CoinType>(sender, amount);
        let fa = spike_amm::coin_wrapper::wrap<CoinType>(coin);
        let token_obj = coin_wrapper::create_fungible_asset<CoinType>();
        if (!primary_fungible_store::primary_store_exists(to, token_obj)) {
            primary_fungible_store::create_primary_store(to, token_obj);
        };
        primary_fungible_store::deposit(to, fa);
    }
 
    public entry fun unwrap_beta<CoinType>(
        sender: &signer,
        to: address,
        amount: u64
    ) {
        let coin_object = coin_wrapper::get_wrapper<CoinType>();
        let bwsup = primary_fungible_store::withdraw(sender, coin_object, amount);
        let original_coin = coin_wrapper::unwrap<CoinType>(bwsup);
        supra_account::deposit_coins(to, original_coin);
    }

    public fun create_locked_pair_for_launchpad(
        sender: &signer,
        tokenA: address,
        tokenB: address
    ) {
        let bwsup_address = get_address_BWSUP();
        assert!(tokenB == bwsup_address, error::invalid_argument(ERROR_TOKEN_B_MUST_BE_BWSUP));
        amm_factory::create_pair_locked(sender, tokenA, tokenB);
    }

    //ADD LIQUIDITY FUNCTIONS
    fun add_liquidity_internal(
        sender: &signer,
        tokenA: Object<Metadata>,
        tokenB: Object<Metadata>,
        amountADesired: u64,
        amountBDesired: u64,
        amountAMin: u64,
        amountBMin: u64,
        to: address,
    ): (u64, u64, u64, Object<Metadata>) {
        let tokenA_addr = object::object_address(&tokenA);
        let tokenB_addr = object::object_address(&tokenB);
        if (!amm_factory::pair_exists(tokenA, tokenB)) {
            amm_factory::create_pair_from_router(sender, tokenA_addr, tokenB_addr);
        };

        let (token0, token1) = sort::sort_two_tokens(tokenA, tokenB);
        let (amount0, amount1) = if (token0 == tokenA) {
            (amountADesired, amountBDesired)
        } else {
            (amountBDesired, amountADesired)
        };
        let (amount0Min, amount1Min) = if (token0 == tokenA) {
            (amountAMin, amountBMin)
        } else {
            (amountBMin, amountAMin)
        };

        let (amount0Optimal, amount1Optimal) = calc_optimal_coin_values(
            token0,
            token1,
            amount0,
            amount1,
            amount0Min,
            amount1Min
        );

        let asset0 = smart_withdraw(sender, token0, amount0Optimal);
        let asset1 = smart_withdraw(sender, token1, amount1Optimal);

        let (lp_amount, lp_token_metadata) = amm_pair::mint(sender, asset0, asset1, to);

        if (token0 == tokenA) {
            (amount0Optimal, amount1Optimal, lp_amount, lp_token_metadata)
        } else {
            (amount1Optimal, amount0Optimal, lp_amount, lp_token_metadata)
        }
    }

    public fun add_liquidity_from_launchpad_aux_beta(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ): (u64, u64, u64, Object<Metadata>) {
        let token = get_canonical_address(token);
        let bwsup_address = get_address_BWSUP();
        let pair_address = amm_factory::get_pair(token, bwsup_address);
        assert!(pair_address != @0x0, error::invalid_argument(ERROR_INVALID_PATH));

        // unlock the pair from launchpad restrictions
        amm_factory::verify_and_unlock_pair(sender, pair_address);

        add_liquidity_coin_aux_beta<SupraCoin>(
            sender,
            token,
            amount_token_desired,
            amount_token_min,
            amount_supra_desired,
            amount_supra_min,
            to,
            deadline
        )
    }

    public fun add_liquidity_from_launchpad_beta(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _, _, _) = add_liquidity_from_launchpad_aux_beta(
            sender,
            token,
            amount_token_desired,
            amount_token_min,
            amount_supra_desired,
            amount_supra_min,
            to,
            deadline
        );
    }

    public entry fun add_liquidity(
        sender: &signer,
        tokenA: address,
        tokenB: address,
        amountADesired: u64,
        amountBDesired: u64,
        amountAMin: u64,
        amountBMin: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _, _, _) = add_liquidity_aux(
            sender, 
            tokenA, 
            tokenB, 
            amountADesired, 
            amountBDesired, 
            amountAMin, 
            amountBMin, 
            to,
            deadline
        );
    }

    public fun add_liquidity_aux(
        sender: &signer,
        tokenA: address,
        tokenB: address,
        amountADesired: u64,
        amountBDesired: u64,
        amountAMin: u64,
        amountBMin: u64,
        to: address,
        deadline: u64
    ): (u64, u64, u64, Object<Metadata>) {
        ensure(deadline); 
        let tokenA = get_canonical_address(tokenA);
        let tokenB = get_canonical_address(tokenB);

        assert!(tokenA != WSUP && tokenB != WSUP, error::invalid_argument(ERROR_USE_BWSUP_INSTEAD));
        validate_token_pair(tokenA, tokenB);
        validate_amount(amountADesired);
        validate_amount(amountBDesired);

        let metaA = object::address_to_object<Metadata>(tokenA);
        let metaB = object::address_to_object<Metadata>(tokenB);
        if (!coin_wrapper::is_wrapper(metaA)) {
            assert!(
                option::is_none(&supra_framework::coin::paired_coin(metaA)),
                error::invalid_argument(ERROR_USE_COIN_FUNCTION)
            );
        };
        if (!coin_wrapper::is_wrapper(metaB)) {
            assert!(
                option::is_none(&supra_framework::coin::paired_coin(metaB)),
                error::invalid_argument(ERROR_USE_COIN_FUNCTION)
            );
        };
        
        assert_is_pure_native_fa(tokenA);
        assert_is_pure_native_fa(tokenB);

        let tokenA_object = object::address_to_object<Metadata>(tokenA);
        let tokenB_object = object::address_to_object<Metadata>(tokenB);
        
        let (amount0, amount1, lp_amount, lp_token_metadata) = add_liquidity_internal(
            sender,
            tokenA_object,
            tokenB_object, 
            amountADesired, 
            amountBDesired, 
            amountAMin, 
            amountBMin,
            to
        );
        
        (amount0, amount1, lp_amount, lp_token_metadata)
    }

    public entry fun add_liquidity_supra(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _, _, _) = add_liquidity_supra_aux(
            sender, 
            token, 
            amount_token_desired, 
            amount_token_min, 
            amount_supra_desired, 
            amount_supra_min, 
            to,
            deadline
        );
    }

    public fun add_liquidity_supra_aux(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_supra_desired: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ): (u64, u64, u64, Object<Metadata>) {
        ensure(deadline);
        let token = get_canonical_address(token);

        validate_token_pair(token, WSUP);
        assert_is_pure_native_fa(token);
        validate_amount(amount_token_desired);
        validate_amount(amount_supra_desired);
        
        let token_object = object::address_to_object<Metadata>(token);
        let supra_object = coin_wrapper::get_wrapper<SupraCoin>(); 
        let supra_addr = object::object_address(&supra_object);

        let (token0, token1) = sort::sort_two_tokens(token_object, supra_object);

        if (!amm_factory::pair_exists(token0, token1)) {
            amm_factory::create_pair_from_router(sender, token, supra_addr);
        };

        let (amount0_desired, amount1_desired) = if (token0 == token_object) {
            (amount_token_desired, amount_supra_desired)
        } else {
            (amount_supra_desired, amount_token_desired)
        };
        
        let (amount0_min, amount1_min) = if (token0 == token_object) {
            (amount_token_min, amount_supra_min)
        } else {
            (amount_supra_min, amount_token_min)
        };

        let (amount0, amount1) = calc_optimal_coin_values(
            token0,
            token1,
            amount0_desired,
            amount1_desired,
            amount0_min,
            amount1_min,
        );

        let (asset0, asset1) = if (token0 == token_object) {
            (
                smart_withdraw(sender, token_object, amount0),
                smart_withdraw(sender, supra_object, amount1)
            )
        } else {
            (
                smart_withdraw(sender, supra_object, amount0),
                smart_withdraw(sender, token_object, amount1)
            )
        };

        let (lp_amount, lp_token_metadata) = amm_pair::mint(sender, asset0, asset1, to);

        if (token0 == token_object) {
            (amount0, amount1, lp_amount, lp_token_metadata)
        } else {
            (amount1, amount0, lp_amount, lp_token_metadata)
        }
    }

    public entry fun add_liquidity_coin<CoinType>(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_coin_desired: u64,
        amount_coin_min: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _, _, _) = add_liquidity_coin_aux<CoinType>(
            sender, 
            token, 
            amount_token_desired, 
            amount_token_min, 
            amount_coin_desired, 
            amount_coin_min, 
            to,
            deadline
        );
    }

    public fun add_liquidity_coin_aux<CoinType>(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_coin_desired: u64,
        amount_coin_min: u64,
        to: address,
        deadline: u64
    ): (u64, u64, u64, Object<Metadata>) {
        add_liquidity_coin_aux_beta<CoinType>(
            sender, 
            token, 
            amount_token_desired, 
            amount_token_min, 
            amount_coin_desired, 
            amount_coin_min, 
            to,
            deadline
        )
    }

    public entry fun add_liquidity_coin_beta<CoinType>(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_coin_desired: u64,
        amount_coin_min: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _, _, _) = add_liquidity_coin_aux_beta<CoinType>(
            sender, 
            token, 
            amount_token_desired, 
            amount_token_min, 
            amount_coin_desired, 
            amount_coin_min, 
            to,
            deadline
        );
    }

    public fun add_liquidity_coin_aux_beta<CoinType>(
        sender: &signer,
        token: address,
        amount_token_desired: u64,
        amount_token_min: u64,
        amount_coin_desired: u64,
        amount_coin_min: u64,
        to: address,
        deadline: u64
    ) : (u64, u64, u64, Object<Metadata>) {
        ensure(deadline);
        let token = get_canonical_address(token);

        let sender_addr = signer::address_of(sender);
        assert_is_pure_native_fa(token);
        let tokenA_object = object::address_to_object<Metadata>(token);
        let tokenB_object = coin_wrapper::create_fungible_asset<CoinType>();

        let tokenB_addr = object::object_address(&tokenB_object);

        validate_token_pair(token, tokenB_addr);
        assert!(amount_token_desired > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));
        assert!(amount_coin_desired > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));

        if (!amm_factory::pair_exists(tokenA_object, tokenB_object)) {
            amm_factory::create_pair_from_router(sender, token, tokenB_addr);
        };

        let (token0_obj, token1_obj) = sort::sort_two_tokens(tokenA_object, tokenB_object);
        let (amount0_desired_sorted, amount1_desired_sorted) = if (token0_obj == tokenA_object) {
            (amount_token_desired, amount_coin_desired)
        } else {
            (amount_coin_desired, amount_token_desired)
        };
        let (amount0_min_sorted, amount1_min_sorted) = if (token0_obj == tokenA_object) {
            (amount_token_min, amount_coin_min)
        } else {
            (amount_coin_min, amount_token_min)
        };

        let (amount0_final_optimal, amount1_final_optimal) = calc_optimal_coin_values(
            token0_obj,
            token1_obj,
            amount0_desired_sorted,
            amount1_desired_sorted,
            amount0_min_sorted,
            amount1_min_sorted
        );
        assert!(amount0_final_optimal > 0, error::invalid_argument(ERROR_INVALID_AMOUNT));
        assert!(amount1_final_optimal > 0, error::invalid_argument(ERROR_INVALID_AMOUNT));

        let (_, amount_to_wrap_B) = if (token0_obj == tokenA_object) {
            (amount0_final_optimal, amount1_final_optimal)
        } else {
            (amount1_final_optimal, amount0_final_optimal)
        };

        wrap_beta<CoinType>(sender, sender_addr, amount_to_wrap_B);

        let asset0 = primary_fungible_store::withdraw(sender, token0_obj, amount0_final_optimal);
        let asset1 = primary_fungible_store::withdraw(sender, token1_obj, amount1_final_optimal);

        let (lp_amount, lp_token_metadata_obj) = amm_pair::mint(sender, asset0, asset1, to);

        let (final_amountA, final_amountB) = if (token0_obj == tokenA_object) {
            (amount0_final_optimal, amount1_final_optimal)
        } else {
            (amount1_final_optimal, amount0_final_optimal)
        };
        (final_amountA, final_amountB, lp_amount, lp_token_metadata_obj)

    }

    public entry fun add_liquidity_coins_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        amountA_coin_desired: u64,
        amountA_coin_min: u64,
        amountB_coin_desired: u64,
        amountB_coin_min: u64,
        to: address,
        deadline: u64
    ) {
        add_liquidity_coins_aux_beta<CoinType_A, CoinType_B>(
            sender,
            amountA_coin_desired,
            amountA_coin_min,
            amountB_coin_desired,
            amountB_coin_min,
            to,
            deadline
        );
    }
    
    public fun add_liquidity_coins_aux_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        amountA_coin_desired: u64,
        amountA_coin_min: u64,
        amountB_coin_desired: u64,
        amountB_coin_min: u64,
        to: address,
        deadline: u64
    ) : (u64, u64, u64, Object<Metadata>)  {
        ensure(deadline);
        let sender_addr = signer::address_of(sender);

        let tokenA_object_wrapped = coin_wrapper::create_fungible_asset<CoinType_A>();
        let tokenB_object_wrapped = coin_wrapper::create_fungible_asset<CoinType_B>();

        let tokenA_addr_wrapped = object::object_address(&tokenA_object_wrapped);
        let tokenB_addr_wrapped = object::object_address(&tokenB_object_wrapped);

        validate_token_pair(tokenA_addr_wrapped, tokenB_addr_wrapped);
        assert!(amountA_coin_desired > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));
        assert!(amountB_coin_desired > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));

        if (!amm_factory::pair_exists(tokenA_object_wrapped, tokenB_object_wrapped)) {
            amm_factory::create_pair_from_router(sender, tokenA_addr_wrapped, tokenB_addr_wrapped);
        };

        let (token0_obj, token1_obj) = sort::sort_two_tokens(tokenA_object_wrapped, tokenB_object_wrapped);
        let (amount0_desired_sorted, amount1_desired_sorted) = if (token0_obj == tokenA_object_wrapped) {
            (amountA_coin_desired, amountB_coin_desired)
        } else {
            (amountB_coin_desired, amountA_coin_desired)
        };
        let (amount0_min_sorted, amount1_min_sorted) = if (token0_obj == tokenA_object_wrapped) {
            (amountA_coin_min, amountB_coin_min)
        } else {
            (amountB_coin_min, amountA_coin_min)
        };

        let (amount0_final_optimal, amount1_final_optimal) = calc_optimal_coin_values(
            token0_obj,
            token1_obj,
            amount0_desired_sorted,
            amount1_desired_sorted,
            amount0_min_sorted,
            amount1_min_sorted
        );
        assert!(amount0_final_optimal > 0, error::invalid_argument(ERROR_INVALID_AMOUNT));
        assert!(amount1_final_optimal > 0, error::invalid_argument(ERROR_INVALID_AMOUNT));

        let (amount_to_wrap_A, amount_to_wrap_B) = if (token0_obj == tokenA_object_wrapped) {
            (amount0_final_optimal, amount1_final_optimal)
        } else {
            (amount1_final_optimal, amount0_final_optimal)
        };

        wrap_beta<CoinType_A>(sender, sender_addr, amount_to_wrap_A);
        wrap_beta<CoinType_B>(sender, sender_addr, amount_to_wrap_B);

        let asset0 = primary_fungible_store::withdraw(sender, token0_obj, amount0_final_optimal);
        let asset1 = primary_fungible_store::withdraw(sender, token1_obj, amount1_final_optimal);

        let (lp_amount, lp_token_metadata_obj) = amm_pair::mint(sender, asset0, asset1, to);

        let (final_amountA, final_amountB) = if (token0_obj == tokenA_object_wrapped) {
            (amount0_final_optimal, amount1_final_optimal)
        } else {
            (amount1_final_optimal, amount0_final_optimal)
        };
        (final_amountA, final_amountB, lp_amount, lp_token_metadata_obj)
    }

    //REMOVE LIQUIDITY FUNCTIONS 
    fun remove_liquidity_internal(
        sender: &signer,
        tokenA: Object<Metadata>,
        tokenB: Object<Metadata>,
        liquidity: u64,
        amountAMin: u64,
        amountBMin: u64,
    ): (FungibleAsset, FungibleAsset) {
        assert!(
            liquidity > 0,
            error::invalid_argument(ERROR_ZERO_AMOUNT)
        );
        assert!(
            object::object_address(&tokenA) != object::object_address(&tokenB),
            error::invalid_argument(ERROR_IDENTICAL_TOKENS)
        );
        
        let pair = amm_pair::liquidity_pool(tokenA, tokenB);
        let (redeemedA, redeemedB) = amm_pair::burn(sender, pair, liquidity);

        let (ret_a, ret_b) = if (sort::is_sorted_two(tokenA, tokenB)) {
            (redeemedA, redeemedB)
        } else {
            (redeemedB, redeemedA)
        };

        assert!(
            fungible_asset::amount(&ret_a) >= amountAMin && fungible_asset::amount(&ret_b) >= amountBMin,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        (ret_a, ret_b)
    }

    public entry fun remove_liquidity(
        sender: &signer,
        tokenA: address,
        tokenB: address,
        liquidity: u64,
        amountAMin: u64,
        amountBMin: u64,
        to: address,
        deadline: u64
    ) {
        let bwsup_address = get_address_BWSUP();
        let tokenA = get_canonical_address(tokenA);
        let tokenB = get_canonical_address(tokenB);
        assert!(
            tokenA != bwsup_address && tokenB != bwsup_address,
            error::invalid_argument(ERROR_BWSUP_AS_OUTPUT_NOT_ALLOWED)
        );

        let (_, _) = remove_liquidity_aux(
            sender, 
            tokenA, 
            tokenB, 
            liquidity, 
            amountAMin, 
            amountBMin, 
            to,
            deadline
        );
    }

    public fun remove_liquidity_aux(
        sender: &signer,
        tokenA: address,
        tokenB: address,
        liquidity: u64,
        amountAMin: u64,
        amountBMin: u64,
        to: address,
        deadline: u64
    ): (u64, u64) {
        ensure(deadline);

        let tokenA = get_canonical_address(tokenA);
        let tokenB = get_canonical_address(tokenB);

        let tokenA_object = object::address_to_object<Metadata>(tokenA);
        let tokenB_object = object::address_to_object<Metadata>(tokenB);
        
        let (assetA, assetB) = remove_liquidity_internal(
            sender, 
            tokenA_object,
            tokenB_object, 
            liquidity, 
            amountAMin, 
            amountBMin
        );

        let amountA = fungible_asset::amount(&assetA);
        let amountB = fungible_asset::amount(&assetB);
        
        assert!(
            amountA >= amountAMin,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );
        assert!(
            amountB >= amountBMin,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        primary_fungible_store::deposit(to, assetA);
        primary_fungible_store::deposit(to, assetB);

        (amountA, amountB)
    }

    public entry fun remove_liquidity_supra(
        sender: &signer,
        token: address,
        liquidity: u64,
        amount_token_min: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ) {
        let (_, _) = remove_liquidity_supra_aux(
            sender, 
            token, 
            liquidity, 
            amount_token_min, 
            amount_supra_min, 
            to,
            deadline
        );
    }

    public fun remove_liquidity_supra_aux(
        sender: &signer,
        token: address,
        liquidity: u64,
        amount_token_min: u64,
        amount_supra_min: u64,
        to: address,
        deadline: u64
    ): (u64, u64) {
        ensure(deadline);

        let token = get_canonical_address(token);

        let token_object = object::address_to_object<Metadata>(token);
        let supra_object = coin_wrapper::get_wrapper<SupraCoin>();

        let (asset_token, asset_supra) = remove_liquidity_internal(
            sender, 
            token_object,
            supra_object, 
            liquidity, 
            amount_token_min, 
            amount_supra_min
        );

        let amountA = fungible_asset::amount(&asset_token);
        let amountB = fungible_asset::amount(&asset_supra);

        smart_deposit(to, asset_token);

        let supra_legacy_coin = coin_wrapper::unwrap<SupraCoin>(asset_supra);
        
        supra_account::deposit_coins(to, supra_legacy_coin);

        (amountA, amountB)
    }

    public entry fun remove_liquidity_coin_beta<CoinType>(
        sender: &signer,
        token: address,
        liquidity: u64,
        amount_token_min: u64,
        amount_coin_min: u64,
    ) {
        let (_, _) = remove_liquidity_coin_aux_beta<CoinType>(
            sender, 
            token, 
            liquidity, 
            amount_token_min, 
            amount_coin_min,
        );
    }

    public fun remove_liquidity_coin_aux_beta<CoinType>(
        sender: &signer,
        token: address,
        liquidity: u64,
        amount_token_min: u64,
        amount_coin_min: u64,
    ): (u64, u64) {
        let token = get_canonical_address(token);

        let token_object = object::address_to_object<Metadata>(token);
        let coin_object = coin_wrapper::get_wrapper<CoinType>();

        let (asset_token, asset_coin) = remove_liquidity_internal(
            sender, 
            token_object,
            coin_object, 
            liquidity, 
            amount_token_min, 
            amount_coin_min
        );

        let amountA = fungible_asset::amount(&asset_token);
        let amountB = fungible_asset::amount(&asset_coin);

        assert!(
            amountA >= amount_token_min,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );
        assert!(
            amountB >= amount_coin_min,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        ); 

        let to = signer::address_of(sender);
        primary_fungible_store::deposit(to, asset_token);
        let legacy_coin = coin_wrapper::unwrap<CoinType>(asset_coin);
        supra_account::deposit_coins(to, legacy_coin);

        (amountA, amountB)
    }

    public entry fun remove_liquidity_coins_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        liquidity: u64,
        amount_coin_A_min: u64,
        amount_coin_B_min: u64,
        deadline: u64
    ) {
        remove_liquidity_coins_aux_beta<CoinType_A, CoinType_B>(
            sender,
            liquidity,
            amount_coin_A_min,
            amount_coin_B_min,
            deadline
        );
    }
    
    public fun remove_liquidity_coins_aux_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        liquidity: u64,
        amount_coin_A_min: u64,
        amount_coin_B_min: u64,
        deadline: u64
    ) : (u64, u64) {
        ensure(deadline);
        let sender_addr = signer::address_of(sender);

        let coin_metadata_A = coin_wrapper::get_wrapper<CoinType_A>();
        let coin_metadata_B = coin_wrapper::get_wrapper<CoinType_B>();

        let (assetA_from_pool, assetB_from_pool) = remove_liquidity_internal(
            sender,
            coin_metadata_A,
            coin_metadata_B,
            liquidity,
            amount_coin_A_min,
            amount_coin_B_min,
        );

        let amountA = fungible_asset::amount(&assetA_from_pool);
        let amountB = fungible_asset::amount(&assetB_from_pool);

        if (!primary_fungible_store::primary_store_exists(sender_addr, coin_metadata_A)) {
            primary_fungible_store::create_primary_store(sender_addr, coin_metadata_A);
        };
        if (!primary_fungible_store::primary_store_exists(sender_addr, coin_metadata_B)) {
            primary_fungible_store::create_primary_store(sender_addr, coin_metadata_B);
        };

        primary_fungible_store::deposit(sender_addr, assetA_from_pool);
        primary_fungible_store::deposit(sender_addr, assetB_from_pool);

        if (amountA > 0) {
            unwrap_beta<CoinType_A>(sender, sender_addr, amountA);
        };
        if (amountB > 0) {
            unwrap_beta<CoinType_B>(sender, sender_addr, amountB);
        };

        (amountA, amountB)
    }

    //MASTER SWAP FUNCTION
    public fun swap(
        sender: &signer,
        token_in: FungibleAsset,
        to_token: Object<Metadata>,
        to: address,
    ): FungibleAsset {
        let from_token = fungible_asset::asset_metadata(&token_in);
        let (token0, token1) = sort::sort_two_tokens(from_token, to_token);
        let pair = amm_pair::liquidity_pool(token0, token1);

        let amount_in = fungible_asset::amount(&token_in);

        let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);
        let (reserve_in, reserve_out) = if (from_token == token0) {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        let amount_out = utils::get_amount_out(amount_in, reserve_in, reserve_out);
        let (zero, coins_out);
        if (sort::is_sorted_two(from_token, to_token)) {
            (zero, coins_out) = amm_pair::swap(sender, pair, token_in, 0, fungible_asset::zero(to_token), amount_out, to);
        } else {
            (coins_out, zero) = amm_pair::swap(sender, pair, fungible_asset::zero(to_token), amount_out, token_in, 0, to);
        };
        
        fungible_asset::destroy_zero(zero);
        coins_out
    }

    //SWAP FUNCTIONS FUNGIBLE ASSETS
public entry fun swap_exact_tokens_for_tokens(
        sender: &signer,
        amount_in: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64
    ) {
        ensure(deadline);
        let path = normalize_path(path);
        
        let length = vector::length(&path);
        assert!(length >= 2, error::invalid_argument(ERROR_INVALID_PATH));

        let sender_addr = signer::address_of(sender);

        let current_processing_asset = smart_withdraw(
            sender,
            object::address_to_object<Metadata>(*vector::borrow(&path, 0)),
            amount_in
        );

        let i = 0u64;
        while (i < length - 1) {
            let next_token_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );

            let swapped_asset_this_hop = swap(
                sender,
                current_processing_asset,
                next_token_metadata,
                sender_addr 
            );

            current_processing_asset = swapped_asset_this_hop;
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(
            final_amount >= amount_out_min,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        primary_fungible_store::deposit(to, current_processing_asset);
    }

    fun swap_exact_input_internal(
        sender: &signer,
        amount_in: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address
    ): u64 {
        let length = vector::length(&path);
        assert!(length >= 2, error::invalid_argument(ERROR_INVALID_PATH));

        let sender_addr = signer::address_of(sender);

        let current_processing_asset = smart_withdraw(
            sender,
            object::address_to_object<Metadata>(*vector::borrow(&path, 0)),
            amount_in
        );

        let i = 0u64;
        while (i < length - 1) {
            let next_token_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );

            let swapped_asset_this_hop = swap(
                sender,
                current_processing_asset,
                next_token_metadata,
                sender_addr 
            );

            current_processing_asset = swapped_asset_this_hop;
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(
            final_amount >= amount_out_min,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        smart_deposit(to, current_processing_asset);
        final_amount
    }

    public entry fun swap_exact_coin_for_tokens_beta<CoinType>(
        sender: &signer,
        amount_coin: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        ensure(deadline);
        let path = normalize_path(path);
        let sender_addr = signer::address_of(sender);

        smart_inject_path_start<CoinType>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        wrap_beta<CoinType>(sender, sender_addr, amount_coin);

        swap_exact_input_internal(sender, amount_coin, amount_out_min, path, to);
    }

    public entry fun swap_tokens_for_exact_tokens(
        sender: &signer,
        amount_out: u64,
        amount_in_coin_max: u64,
        path: vector<address>,
        to: address,
        deadline: u64
    ) {
        ensure(deadline);
        let path = normalize_path(path);
        let total_amount_in_calculated = calculate_amount_in_for_exact_out(path, amount_out);
        assert!(
            total_amount_in_calculated <= amount_in_coin_max,
            error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT)
        );

        swap_for_exact_output_internal(sender, total_amount_in_calculated, amount_out, path, to);
    }

    fun calculate_amount_in_for_exact_out(
        path: vector<address>, 
        amount_out: u64
    ): u64 {
        let path_len = vector::length(&path);
        assert!(path_len >= 2, error::invalid_argument(ERROR_INVALID_PATH));

        let i = path_len - 1;
        let current_target_amount = amount_out;

        while (i > 0) {
            let from_token_obj = object::address_to_object<Metadata>(*vector::borrow(&path, i - 1));
            let to_token_obj = object::address_to_object<Metadata>(*vector::borrow(&path, i));

            let (token0_calc, token1_calc) = sort::sort_two_tokens(from_token_obj, to_token_obj);
            let pair_calc = amm_pair::liquidity_pool(token0_calc, token1_calc);
            let (r0, r1, _) = amm_pair::get_reserves(pair_calc);

            let (reserve_of_from_token, reserve_of_to_token) = if (object::object_address(&from_token_obj) == object::object_address(&token0_calc)) {
                (r0, r1)
            } else {
                (r1, r0)
            };

            current_target_amount = utils::get_amount_in(
                current_target_amount,
                reserve_of_from_token,
                reserve_of_to_token
            );
            i = i - 1;
        };
        current_target_amount
    }

    fun swap_for_exact_output_internal(
        sender: &signer,
        total_amount_in: u64,
        amount_out_expected: u64,
        path: vector<address>,
        to: address
    ) {
        let path_len = vector::length(&path);
        assert!(path_len >= 2, error::invalid_argument(ERROR_INVALID_PATH));
        let sender_addr = signer::address_of(sender);

        let initial_token_obj = object::address_to_object<Metadata>(*vector::borrow(&path, 0));

        let current_processing_asset = smart_withdraw(
            sender,
            initial_token_obj,
            total_amount_in
        );

        let i = 0u64;
        while (i < path_len - 1) {
            let next_token_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );

            current_processing_asset = swap(
                sender,
                current_processing_asset,
                next_token_metadata,
                sender_addr
            );

            i = i + 1;
        };
        let final_amount_obtained = fungible_asset::amount(&current_processing_asset);
        let tolerance = (path_len - 1); 
        assert!(
            final_amount_obtained + tolerance >= amount_out_expected,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        smart_deposit(to, current_processing_asset);
    }

    public entry fun swap_coin_for_exact_tokens_beta<CoinType>(
        sender: &signer,
        amount_out: u64,
        amount_in_coin_max: u64,
        path: vector<address>,
        to: address,
        deadline: u64
    ) {
        ensure(deadline);        
        let path = normalize_path(path);

        smart_inject_path_start<CoinType>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        let sender_addr = signer::address_of(sender);

        let total_amount_in_calculated = calculate_amount_in_for_exact_out(path, amount_out);
        assert!(
            total_amount_in_calculated <= amount_in_coin_max,
            error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT)
        );

        wrap_beta<CoinType>(sender, sender_addr, total_amount_in_calculated);
        swap_for_exact_output_internal(sender, total_amount_in_calculated, amount_out, path, to);
    }

    public entry fun swap_supra_for_exact_tokens(
        sender: &signer,
        amount_supra_max: u64,
        amount_out: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        swap_supra_for_exact_tokens_internal(sender, amount_supra_max, amount_out, path, to, deadline, true);
    }

    fun swap_supra_for_exact_tokens_internal(
        sender: &signer,
        amount_supra_max: u64,
        amount_out: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
        _is_wsup: bool,
    ) {
        ensure(deadline);
        
        let path = normalize_path(path);
        let bwsup_addr = get_address_BWSUP();
        
        if (vector::is_empty(&path) || *vector::borrow(&path, 0) != bwsup_addr) {
            vector::insert(&mut path, 0, bwsup_addr);
        };
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));

        let final_length = vector::length(&path);
        assert!(final_length >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));

        let sender_addr = signer::address_of(sender);

        let supra_needed = calculate_amount_in_for_exact_out(path, amount_out);
        assert!(supra_needed <= amount_supra_max, error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT));

        let bwsup_metadata = object::address_to_object<Metadata>(bwsup_addr);
        let current_processing_asset = smart_withdraw(sender, bwsup_metadata, supra_needed);

        let i = 0u64;
        while (i < final_length  - 1) {
            let next_token_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );

            current_processing_asset = swap(
                sender,
                current_processing_asset,
                next_token_metadata,
                sender_addr 
            );
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(final_amount >= amount_out, error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT));

        smart_deposit(to, current_processing_asset);
    }

    public entry fun swap_supra_for_exact_tokens_beta(
        sender: &signer,
        amount_supra_max: u64,
        amount_out: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        swap_supra_for_exact_tokens_internal(sender, amount_supra_max, amount_out, path, to, deadline, false);
    }

    public entry fun swap_exact_supra_for_tokens(
        sender: &signer,
        amount_supra: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_exact_supra_for_tokens_internal(sender, amount_supra, amount_out_min, path, to, deadline, true);
        smart_deposit(to, current_processing_asset);
    }

    fun swap_exact_supra_for_tokens_internal(
        sender: &signer,
        amount_supra: u64,
        amount_out_min: u64,
        path: vector<address>,
        _to: address,
        deadline: u64,
        _is_wsup: bool,
    ): FungibleAsset {
        ensure(deadline);
        
        let path = normalize_path(path);        
        let bwsup_addr = get_address_BWSUP();

        if (vector::is_empty(&path) || *vector::borrow(&path, 0) != bwsup_addr) {
            vector::insert(&mut path, 0, bwsup_addr);
        };

        let final_length = vector::length(&path);
        assert!(final_length >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        
        let sender_addr = signer::address_of(sender);
        
        let bwsup_metadata = object::address_to_object<Metadata>(bwsup_addr);
        let current_processing_asset = smart_withdraw(sender, bwsup_metadata, amount_supra);
        
        let i = 0u64;
        while (i < final_length  - 1) {
            let next_token_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );  
            
            current_processing_asset = swap(
                sender,
                current_processing_asset,
                next_token_metadata,
                sender_addr
            );
            i = i + 1;
        };
        
        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(final_amount >= amount_out_min, error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT));
    
        current_processing_asset
    }

    public entry fun swap_exact_supra_for_tokens_beta(
        sender: &signer,
        amount_supra: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_exact_supra_for_tokens_internal(sender, amount_supra, amount_out_min, path, to, deadline, false);
        primary_fungible_store::deposit(to, current_processing_asset);
    }

    public entry fun swap_tokens_for_exact_supra(
        sender: &signer,
        amount_out: u64,
        amount_in_max: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_tokens_for_exact_supra_internal(
            sender,
            amount_out,
            amount_in_max,
            path,
            deadline,
            true
        );
        
        smart_deposit(to, current_processing_asset);
    }

    fun swap_tokens_for_exact_supra_internal(
        sender: &signer,
        amount_out: u64,
        amount_in_max: u64,
        path: vector<address>,
        deadline: u64,
        is_wsup: bool,
    ): FungibleAsset {
        ensure(deadline);
        let path = normalize_path(path); 

        let bwsup_address = get_address_BWSUP();
        let path_len = vector::length(&path);

        if (path_len == 0 || *vector::borrow(&path, path_len - 1) != bwsup_address) {
            vector::push_back(&mut path, bwsup_address);
        };

        let final_length = vector::length(&path);
        assert!(final_length >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        
        if (!is_wsup) {
            ensure_path_does_not_start_with(&path, bwsup_address);
        };

        let sender_addr = signer::address_of(sender);

        let total_amount_in_calculated = calculate_amount_in_for_exact_out(path, amount_out);
        assert!(
            total_amount_in_calculated <= amount_in_max,
            error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT)
        );

        let initial_token_obj = object::address_to_object<Metadata>(*vector::borrow(&path, 0));
        let current_processing_asset = smart_withdraw(
            sender,
            initial_token_obj,
            total_amount_in_calculated
        );

        let i = 0u64;
        while (i < final_length - 1) {
            let next_token_in_path_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );
            
            current_processing_asset = swap(
                sender,
                current_processing_asset,
                next_token_in_path_metadata,
                sender_addr 
            );
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(
            final_amount >= amount_out,
            error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT)
        );

        current_processing_asset
    }

    public entry fun swap_tokens_for_exact_supra_beta(
        sender: &signer,
        amount_out: u64,
        amount_in_max: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_tokens_for_exact_supra_internal(
            sender,
            amount_out,
            amount_in_max,
            path,
            deadline,
            false
        );
        let sender_addr = signer::address_of(sender);
        primary_fungible_store::deposit(sender_addr, current_processing_asset);
        unwrap_beta<SupraCoin>(sender, to, amount_out);
    }

    public entry fun swap_exact_tokens_for_supra(
        sender: &signer,
        amount_in: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_exact_tokens_for_supra_internal(
            sender,
            amount_in,
            amount_out_min,
            path,
            to,
            deadline,
            true
        );
        smart_deposit(to, current_processing_asset);
    }

    fun swap_exact_tokens_for_supra_internal(
        sender: &signer,
        amount_in: u64,
        amount_out_min: u64,
        path: vector<address>,
        _to: address,
        deadline: u64,
        is_wsup: bool,
    ): FungibleAsset {
        ensure(deadline);
        let path = normalize_path(path);

        let bwsup_address = get_address_BWSUP();
        let path_len = vector::length(&path);

        if (path_len == 0 || *vector::borrow(&path, path_len - 1) != bwsup_address) {
            vector::push_back(&mut path, bwsup_address);
        };

        let final_length = vector::length(&path);
        assert!(final_length >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));

        if (!is_wsup) {
            ensure_path_does_not_start_with(&path, bwsup_address);
        };

        let sender_addr = signer::address_of(sender);

        let initial_token_metadata = object::address_to_object<Metadata>(*vector::borrow(&path, 0));
        let current_processing_asset = smart_withdraw(
            sender,
            initial_token_metadata,
            amount_in
        );

        let i = 0u64;
        while (i < final_length - 1) {
            let next_token_in_path_metadata = object::address_to_object<Metadata>(
                *vector::borrow(&path, i + 1)
            );

            current_processing_asset = swap(
                sender,
                current_processing_asset,
                next_token_in_path_metadata,
                sender_addr 
            );
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_processing_asset);
        assert!(final_amount >= amount_out_min, error::invalid_state(ERROR_INSUFFICIENT_OUTPUT_AMOUNT));

        current_processing_asset
    }

    public entry fun swap_exact_tokens_for_supra_beta(
        sender: &signer,
        amount_in: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        let current_processing_asset = swap_exact_tokens_for_supra_internal(
            sender,
            amount_in,
            amount_out_min,
            path,
            to,
            deadline,
            false
        );
        let sender_addr = signer::address_of(sender);
        let bwsup_amount = fungible_asset::amount(&current_processing_asset);
        primary_fungible_store::deposit(sender_addr, current_processing_asset);
        unwrap_beta<SupraCoin>(sender, to, bwsup_amount);
    }

    public entry fun swap_exact_coin_for_tokens<CoinType>(
        sender: &signer,
        amount_coin: u64,
        amount_out_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        ensure(deadline);
        let path = normalize_path(path); 
        let sender_addr = signer::address_of(sender);

        smart_inject_path_start<CoinType>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        wrap_beta<CoinType>(sender, sender_addr, amount_coin);

        swap_exact_input_internal(sender, amount_coin, amount_out_min, path, to);
    }
    
    public entry fun swap_coin_for_exact_tokens<CoinType>(
        sender: &signer,
        amount_coin_max: u64,
        amount_out: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        ensure(deadline);
        let path = normalize_path(path); 
        let sender_addr = signer::address_of(sender);

        smart_inject_path_start<CoinType>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        let total_amount_in_calculated = calculate_amount_in_for_exact_out(path, amount_out);

        assert!(
            total_amount_in_calculated <= amount_coin_max,
            error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT)
        );

        wrap_beta<CoinType>(sender, sender_addr, total_amount_in_calculated);

        swap_for_exact_output_internal(sender, total_amount_in_calculated, amount_out, path, to);
    }

    public entry fun swap_exact_tokens_for_coins_beta<CoinType>(
        sender: &signer,
        amount_in: u64,
        amount_out_coin_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64,
    ) {
        ensure(deadline);
        let path = normalize_path(path); 
        let sender_addr = signer::address_of(sender);

        smart_inject_path_end<CoinType>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));

        let bwsup_address = get_address_BWSUP();
        ensure_path_does_not_start_with(&path, bwsup_address);

        let baddr = *vector::borrow(&path, vector::length(&path) - 1);
        let is_b_supra = (baddr == bwsup_address);

        if (is_b_supra) {
            // If it's Supra, smart_deposit unwraps it automatically,
            // so we simply deposit it without doing "unwrap_beta".
            swap_exact_input_internal(
                sender,
                amount_in,
                amount_out_coin_min,
                path,
                to,
            );
        } else {
            // If it's another token, we do the normal process and unwrap.
            let amount_out_wrapped_coin = swap_exact_input_internal(
                sender,
                amount_in,
                amount_out_coin_min,
                path,
                sender_addr,
            );

            unwrap_beta<CoinType>(sender, to, amount_out_wrapped_coin);
        }
    }
    
    public entry fun swap_exact_coins_for_coins_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        amount_in_coin: u64,
        amount_out_coin_min: u64,
        path: vector<address>,
        to: address,
        deadline: u64
    ) {
        ensure(deadline);
        let path = normalize_path(path);
        let sender_addr = signer::address_of(sender);

        smart_inject_path_start<CoinType_A>(&mut path);
        smart_inject_path_end<CoinType_B>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));
        let baddr = *vector::borrow(&path, vector::length(&path) - 1);
        let is_b_supra = (baddr == get_address_BWSUP());

        wrap_beta<CoinType_A>(sender, sender_addr, amount_in_coin);

        if (is_b_supra) {
            swap_exact_input_internal(
                sender,
                amount_in_coin,
                amount_out_coin_min,
                path,
                to 
            );
        } else {
            let amount_out = swap_exact_input_internal(
                sender,
                amount_in_coin,
                amount_out_coin_min,
                path,
                sender_addr
            );

            unwrap_beta<CoinType_B>(sender, to, amount_out);
        }
    }

    public entry fun swap_coins_for_exact_coins_beta<CoinType_A, CoinType_B>(
        sender: &signer,
        amount_out_coin: u64,
        amount_in_coin_max: u64,
        path: vector<address>,
        to: address,
        deadline: u64
    ) {
        ensure(deadline);
        let path = normalize_path(path);
        let sender_addr = signer::address_of(sender);

        smart_inject_path_start<CoinType_A>(&mut path);
        smart_inject_path_end<CoinType_B>(&mut path);
        assert!(vector::length(&path) >= MIN_PATH_LENGTH, error::invalid_argument(ERROR_INVALID_PATH_LENGTH));

        let b_addr = *vector::borrow(&path, vector::length(&path) - 1);
        let is_b_supra = (b_addr == get_address_BWSUP());

        let total_amount_in_calculated = calculate_amount_in_for_exact_out(path, amount_out_coin);
        assert!(
            total_amount_in_calculated <= amount_in_coin_max,
            error::invalid_state(ERROR_INSUFFICIENT_INPUT_AMOUNT)
        );

        wrap_beta<CoinType_A>(sender, sender_addr, total_amount_in_calculated);

        if (is_b_supra) {
            swap_for_exact_output_internal(
                sender, 
                total_amount_in_calculated, 
                amount_out_coin, 
                path, 
                to 
            );
        } else {
            swap_for_exact_output_internal(
                sender, 
                total_amount_in_calculated, 
                amount_out_coin, 
                path, 
                sender_addr 
            );

            unwrap_beta<CoinType_B>(sender, to, amount_out_coin);
        }
    }
    
    #[view]
    public fun get_address_BWSUP(): address {
        let metadata = coin_wrapper::get_wrapper<SupraCoin>();
        object::object_address(&metadata)
    }

    #[view]
    public fun view_remove_liquidity(
        tokenA: address,
        tokenB: address,
        liquidity: u64
    ): (u64, u64) {
        let tokenA_object = object::address_to_object<Metadata>(tokenA);
        let tokenB_object = object::address_to_object<Metadata>(tokenB);

        let tokenA_clean = normalize_metadata(tokenA_object);
        let tokenB_clean = normalize_metadata(tokenB_object);

        assert!(
            liquidity > 0,
            error::invalid_argument(ERROR_ZERO_AMOUNT)
        );
        assert!(
            object::object_address(&tokenA_clean) != object::object_address(&tokenB_clean),
            error::invalid_argument(ERROR_IDENTICAL_TOKENS)
        );

        let pair = amm_pair::liquidity_pool(tokenA_clean, tokenB_clean);

        let (reserve_a, reserve_b, _) = amm_pair::get_reserves(pair);
        let total_supply = amm_pair::lp_token_supply(pair);

        let expected_a = (liquidity as u128) * (reserve_a as u128) / (total_supply as u128);
        let expected_b = (liquidity as u128) * (reserve_b as u128) / (total_supply as u128);

        if (sort::is_sorted_two(tokenA_clean, tokenB_clean)) {
            ((expected_a as u64), (expected_b as u64))
        } else {
            ((expected_b as u64), (expected_a as u64))
        }
    }

    #[view]
    public fun get_amounts_out(
        amount_in: u64,
        path: vector<Object<Metadata>>,
    ): vector<u64> {
        assert!(
            vector::length(&path) >= 2,
            error::invalid_argument(ERROR_INVALID_PATH)
        );
        let amounts = vector::empty<u64>();
        let path_length = vector::length(&path);
        let i = 0;
        while (i < path_length) {
            vector::push_back(&mut amounts, 0);
            i = i + 1;
        };

        *vector::borrow_mut(&mut amounts, 0) = amount_in;

        let k = 0;
        while (k < path_length - 1) {
            let token_a_raw = *vector::borrow(&path, k);
            let token_b_raw = *vector::borrow(&path, k + 1);

            let token_a = normalize_metadata(token_a_raw);
            let token_b = normalize_metadata(token_b_raw);

            let (token0, token1) = sort::sort_two_tokens(token_a, token_b);
            let pair = amm_pair::liquidity_pool(token0, token1);
            let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);
            
            let token_a_addr = object::object_address(&token_a);
            let token0_addr = object::object_address(&token0);
            
            let (reserve_in, reserve_out) = if (token_a_addr == token0_addr) {
                (reserve0, reserve1)
            } else {
                (reserve1, reserve0)
            };
            
            let amount = *vector::borrow(&amounts, k);
            let amount_out = utils::get_amount_out(amount, reserve_in, reserve_out);
            *vector::borrow_mut(&mut amounts, k + 1) = amount_out;
            
            k = k + 1;
        };

        amounts
    }

    fun normalize_metadata(token: Object<Metadata>): Object<Metadata> {
        let token_addr = object::object_address(&token);
        let canonical_addr = get_canonical_address(token_addr);
        object::address_to_object<Metadata>(canonical_addr)
    }

    #[view]
    public fun get_amounts_in(
        amount_out: u64,
        path: vector<Object<Metadata>>,
    ): vector<u64> {
        assert!(
            vector::length(&path) >= 2,
            error::invalid_argument(ERROR_INVALID_PATH)
        );
        let amounts = vector::empty<u64>();
        let path_length = vector::length(&path);
        let i = 0;
        while (i < path_length) {
            vector::push_back(&mut amounts, 0);
            i = i + 1;
        };

        *vector::borrow_mut(&mut amounts, path_length - 1) = amount_out;

        let k = path_length - 1;
        while (k > 0) {
            let token_a_raw = *vector::borrow(&path, k - 1);
            let token_b_raw = *vector::borrow(&path, k);

            let token_a = normalize_metadata(token_a_raw);
            let token_b = normalize_metadata(token_b_raw);

            let (token0, token1) = sort::sort_two_tokens(token_a, token_b);
            let pair = amm_pair::liquidity_pool(token0, token1);
            let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);
            
            let token_a_addr = object::object_address(&token_a);
            let token0_addr = object::object_address(&token0);
            
            let (reserve_in, reserve_out) = if (token_a_addr == token0_addr) {
                (reserve0, reserve1)
            } else {
                (reserve1, reserve0)
            };

            let amount = *vector::borrow(&amounts, k);
            let amount_in = utils::get_amount_in(amount, reserve_in, reserve_out);
            *vector::borrow_mut(&mut amounts, k - 1) = amount_in;
            
            k = k - 1;
        };

        amounts
    }
}