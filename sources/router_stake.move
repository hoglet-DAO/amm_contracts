module spike_staking::router_stake {
    use std::option;
    use std::signer;
    use std::string::String;
    use supra_framework::primary_fungible_store;
    use supra_framework::coin::{Self};
    use supra_framework::object::{Self};
    use supra_framework::fungible_asset::{Metadata};
    use supra_framework::supra_coin::SupraCoin;
    use aptos_std::error;
    use aptos_token::token;

    use spike_staking::stake_fa;
    use spike_staking::coin_wrapper;

    const ERR_USE_COIN_FUNCTION_FOR_SUPRA: u64 = 1;
    const ERR_STAKE_AMOUNT_MUST_BE_POSITIVE: u64 = 2;
    const ERR_REWARD_AMOUNT_MUST_BE_POSITIVE: u64 = 3;

    const WSUP: address = @0xa;

    fun get_canonical_address(addr: address): address {
        if (addr == WSUP) {
            return get_address_BWSUP()
        };
        
        if (object::object_exists<Metadata>(addr)) {
            let metadata = object::address_to_object<Metadata>(addr);
            // 1. If it is already our wrapper, use it.
            if (coin_wrapper::is_wrapper(metadata)) {
                return addr
            };

            // 2. If it is a network wrapper (Coin Paired), convert to our internal wrapper.
            let paired_coin_opt = supra_framework::coin::paired_coin(metadata);
            if (option::is_some(&paired_coin_opt)) {
                let coin_info = option::destroy_some(paired_coin_opt);
                let my_wrapper_opt = coin_wrapper::get_wrapper_for_type_info(coin_info);
                if (option::is_some(&my_wrapper_opt)) {
                    return object::object_address(&option::destroy_some(my_wrapper_opt))
                };
            };
        };
        // 3. If it is a pure FA or cannot be converted, return the original.
        addr
    }

    fun wrap_coin<CoinType>(
        sender: &signer,
        to: address,
        amount: u64
    ) {
        let coin = coin::withdraw<CoinType>(sender, amount);
        let fa = coin_wrapper::wrap<CoinType>(coin);

        let fa_metadata_obj = coin_wrapper::get_wrapper<CoinType>();
        if (!primary_fungible_store::primary_store_exists(to, fa_metadata_obj)) {
            primary_fungible_store::create_primary_store(to, fa_metadata_obj);
        };

        primary_fungible_store::deposit(to, fa);
    }

    fun get_wrapped_fa_address<CoinType>(): address {
        let metadata_obj = coin_wrapper::create_fungible_asset<CoinType>();
        object::object_address(&metadata_obj)
    }

    fun ensure_primary_store_for_address(user_addr: address, token_addr: address) {
        let metadata_obj = object::address_to_object<Metadata>(token_addr);
        if (!primary_fungible_store::primary_store_exists(user_addr, metadata_obj)) {
            primary_fungible_store::create_primary_store(user_addr, metadata_obj);
        }
    }

    public entry fun unwrap<CoinType>(
        sender: &signer,
        to: address,
        amount: u64
    ) {
        let supra_object = coin_wrapper::get_wrapper<CoinType>();
        let bwsup = primary_fungible_store::withdraw(sender, supra_object, amount);
        let supra = coin_wrapper::unwrap<CoinType>(bwsup);
        coin::deposit(to, supra);
    }

    public entry fun register_pool_fa(
        pool_owner: &signer,
        stake_addr: address,
        reward_addr: address,
        reward_amount: u64,          
        duration: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        stake_fa::register_pool(
            pool_owner,           
            stake_addr,           
            reward_addr,          
            reward_amount,       
            duration,            
            option::none()        
                                  
        );
    }

    public entry fun register_pool_coin_fa<StakeCoinType>(
        pool_owner: &signer,
        reward_addr: address,
        reward_amount: u64,
        duration: u64
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        stake_fa::register_pool(
            pool_owner,
            stake_addr,     
            reward_addr,
            reward_amount,
            duration,
            option::none()
        );
    }

    public entry fun register_pool_fa_coin<RewardCoinType>(
        pool_owner: &signer,
        stake_addr: address,
        reward_amount: u64,
        duration: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj); 
        let owner_addr = signer::address_of(pool_owner);
        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));

        wrap_coin<RewardCoinType>(
            pool_owner,
            owner_addr,
            reward_amount
        );
        
        stake_fa::register_pool(
            pool_owner,
            stake_addr,     
            reward_addr,
            reward_amount,
            duration,
            option::none()
        );
    }

    public entry fun register_pool_from_coins<StakeCoinType, RewardCoinType>(
        pool_owner: &signer,
        reward_amount: u64,
        duration: u64
    ) {

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let reward_addr =  get_wrapped_fa_address<RewardCoinType>();
        let owner_addr = signer::address_of(pool_owner);
        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));

        wrap_coin<RewardCoinType>(
            pool_owner,
            owner_addr,
            reward_amount
        );
        
        stake_fa::register_pool(
            pool_owner,
            stake_addr,     
            reward_addr,
            reward_amount,
            duration,
            option::none()
        );
    }

    public entry fun register_pool_with_collection_fa(
        pool_owner: &signer,
        reward_amount: u64,
        stake_addr: address,
        reward_addr: address,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        let boost_config = stake_fa::create_boost_config(collection_owner, collection_name, boost_percent);
        stake_fa::register_pool(
            pool_owner,
            stake_addr,
            reward_addr,
            reward_amount,
            duration,
            option::some(boost_config)
        );
    }

    public entry fun register_pool_with_collection_coin_fa<StakeCoinType>(
        pool_owner: &signer,
        reward_amount: u64,
        reward_addr: address,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let boost_config = stake_fa::create_boost_config(collection_owner, collection_name, boost_percent);
        stake_fa::register_pool(
            pool_owner,
            stake_addr,
            reward_addr,
            reward_amount,
            duration,
            option::some(boost_config)
        );
    }

    public entry fun register_pool_with_collection_fa_coin<RewardCoinType>(
        pool_owner: &signer,
        reward_amount: u64,
        stake_addr: address,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj); 
        let owner_addr = signer::address_of(pool_owner);
        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        wrap_coin<RewardCoinType>(
            pool_owner,
            owner_addr,
            reward_amount
        );
        let boost_config = stake_fa::create_boost_config(collection_owner, collection_name, boost_percent);
        stake_fa::register_pool(
            pool_owner,
            stake_addr,
            reward_addr,
            reward_amount,
            duration,
            option::some(boost_config)
        );
    }

    public entry fun register_pool_with_collection_from_coins<StakeCoinType, RewardCoinType>(
        pool_owner: &signer,
        reward_amount: u64,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let reward_addr = get_wrapped_fa_address<RewardCoinType>();
        let owner_addr = signer::address_of(pool_owner);

        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        wrap_coin<RewardCoinType>(
            pool_owner,
            owner_addr,
            reward_amount
        );
    
        let boost_config = stake_fa::create_boost_config(collection_owner, collection_name, boost_percent);
        stake_fa::register_pool(
            pool_owner,
            stake_addr,
            reward_addr,
            reward_amount,
            duration,
            option::some(boost_config)
        );
    }

    public entry fun stake_fa(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        stake_amount: u64
        ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);
    }

    public entry fun stake_coin_fa<StakeCoinType>(
        user: &signer,
        pool_creator_address: address,
        reward_addr: address,
        stake_amount: u64
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        let user_addr = signer::address_of(user);
        let stake_addr = get_wrapped_fa_address<StakeCoinType>();

        assert!(stake_amount > 0, error::invalid_argument(ERR_STAKE_AMOUNT_MUST_BE_POSITIVE));
        wrap_coin<StakeCoinType>(
            user,
            user_addr,
            stake_amount
        );

        ensure_primary_store_for_address(user_addr, reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr ,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);
    }

    public entry fun stake_fa_coin<RewardCoinType>(
        user: &signer,
        pool_creator_address: address,
        stake_addr: address,
        stake_amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        let reward_addr = get_wrapped_fa_address<RewardCoinType>();
        let user_addr = signer::address_of(user);

        ensure_primary_store_for_address(user_addr, reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);
    }

    public entry fun stake_from_coins<StakeCoinType, RewardCoinType>(
        user: &signer,
        pool_creator_address: address,
        stake_amount: u64
    ) {

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let user_addr = signer::address_of(user);

        assert!(stake_amount > 0, error::invalid_argument(ERR_STAKE_AMOUNT_MUST_BE_POSITIVE));
        wrap_coin<StakeCoinType>(
            user,
            user_addr,
            stake_amount
        );

        let reward_addr = get_wrapped_fa_address<RewardCoinType>();
        ensure_primary_store_for_address(user_addr, reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);
    }

    public entry fun stake_and_boost_fa(
        user: &signer,
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) {

        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);

        let token_id = token::create_token_id_raw(collection_owner, collection_name, token_name, property_version);
        let nft = token::withdraw_token(user, token_id, 1);
        stake_fa::boost(user, pool_key, nft);
    }

    public entry fun stake_and_boost_coin_fa<StakeCoinType>(
        user: &signer,
        pool_creator_address: address,
        reward_addr: address,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        stake_coin_fa<StakeCoinType>(
            user,
            pool_creator_address,
            reward_addr,
            stake_amount
        );

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let token_id = token::create_token_id_raw(collection_owner, collection_name, token_name, property_version);

        let nft = token::withdraw_token(user, token_id, 1);
        stake_fa::boost(user, pool_key, nft);
    }

    public entry fun stake_and_boost_fa_coin<RewardCoinType>(
        user: &signer,
        pool_creator_address: address,
        stake_addr: address,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        let reward_addr = get_wrapped_fa_address<RewardCoinType>();
        let user_addr = signer::address_of(user);
        ensure_primary_store_for_address(user_addr, reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::stake(user, pool_key, stake_amount);

        let token_id = token::create_token_id_raw(collection_owner, collection_name, token_name, property_version);

        let nft = token::withdraw_token(user, token_id, 1);
        stake_fa::boost(user, pool_key, nft);
    }

    public entry fun stake_and_boost_from_coins<StakeCoinType, RewardCoinType>(
        user: &signer,
        pool_creator_address: address,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) {

        stake_from_coins<StakeCoinType, RewardCoinType>(
            user,
            pool_creator_address,
            stake_amount
        );

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let reward_addr = get_wrapped_fa_address<RewardCoinType>();

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let token_id = token::create_token_id_raw(collection_owner, collection_name, token_name, property_version);

        let nft = token::withdraw_token(user, token_id, 1);
        stake_fa::boost(user, pool_key, nft);
    }

    public entry fun unstake_fa(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        unstake_amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);
        assert!(stake_addr != bwsup, error::invalid_argument(ERR_USE_COIN_FUNCTION_FOR_SUPRA));
        assert!(reward_addr != bwsup, error::invalid_argument(ERR_USE_COIN_FUNCTION_FOR_SUPRA));

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let user_addr = signer::address_of(user);
        let unstaked_fa = stake_fa::unstake(user, pool_key, unstake_amount);

        ensure_primary_store_for_address(user_addr, stake_addr);

        primary_fungible_store::deposit(user_addr, unstaked_fa);
    }

    public entry fun unstake_to_coin<StakeCoinType>(
        user: &signer,
        pool_creator_address: address,
        reward_addr: address,
        unstake_amount: u64
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let user_addr = signer::address_of(user);

        let unstaked_fa = stake_fa::unstake(user, pool_key, unstake_amount);
        let unstaked_coin = coin_wrapper::unwrap<StakeCoinType>(unstaked_fa);
        coin::deposit(user_addr, unstaked_coin);
    }    

    public entry fun unstake_and_remove_boost(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        unstake_amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);
        assert!(stake_addr != bwsup, error::invalid_argument(ERR_USE_COIN_FUNCTION_FOR_SUPRA));
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let user_addr = signer::address_of(user);
        let unstaked_fa = stake_fa::unstake(user, pool_key, unstake_amount);

        ensure_primary_store_for_address(user_addr, stake_addr);

        primary_fungible_store::deposit(user_addr, unstaked_fa);
        
        let nft = stake_fa::remove_boost(user, pool_key);
        token::deposit_token(user, nft);
    }

    public entry fun unstake_and_remove_boost_to_coin<StakeCoinType>(
        user: &signer,
        pool_creator_address: address,
        reward_addr: address,
        unstake_amount: u64
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);
        assert!(reward_addr != bwsup, error::invalid_argument(ERR_USE_COIN_FUNCTION_FOR_SUPRA));
        let stake_addr = get_wrapped_fa_address<StakeCoinType>();

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let nft = stake_fa::remove_boost(user, pool_key);
        token::deposit_token(user, nft);

        unstake_to_coin<StakeCoinType>(
            user,
            pool_creator_address,
            reward_addr,
            unstake_amount
        );
    }
    
    public entry fun harvest_fa(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);
        assert!(reward_addr != bwsup, error::invalid_argument(ERR_USE_COIN_FUNCTION_FOR_SUPRA));
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let user_addr = signer::address_of(user);
        let (_, reward_fa) = stake_fa::harvest(user, pool_key);

        ensure_primary_store_for_address(user_addr, reward_addr);

        primary_fungible_store::deposit(user_addr, reward_fa);
    }

    public entry fun harvest_to_coin<RewardCoinType>(
        user: &signer,
        pool_creator_address: address,
        stake_addr: address,
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let user_addr = signer::address_of(user);
        let (_earned_amount, reward_fa) = stake_fa::harvest(user, pool_key); 

        let reward_coin = coin_wrapper::unwrap<RewardCoinType>(reward_fa);
        if (!coin::is_account_registered<RewardCoinType>(user_addr)) {
            coin::register<RewardCoinType>(user);
        };
        coin::deposit(user_addr, reward_coin);
    }

    public entry fun deposit_reward_assets(
        depositor: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        reward_amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::deposit_reward_assets(depositor, pool_key, reward_amount);
    }

    public entry fun deposit_reward_coins<RewardCoinType>(
        depositor: &signer,
        pool_creator_address: address,
        stake_addr: address,
        reward_amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj);
        let depositor_addr = signer::address_of(depositor);
        assert!(reward_amount > 0, error::invalid_argument(ERR_REWARD_AMOUNT_MUST_BE_POSITIVE));
        wrap_coin<RewardCoinType>(
            depositor,
            depositor_addr,
            reward_amount
        );

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        stake_fa::deposit_reward_assets(depositor, pool_key, reward_amount);
    }

    // [NEW] Entry point to increase RPS (Boost) using Fungible Asset directly.
    public entry fun deposit_reward_for_rate_growth_fa(
        depositor: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::deposit_reward_for_rate_growth(depositor, pool_key, amount);
    }

    // [NEW] Entry point to increase RPS (Boost) using Coins (e.g. AptosCoin/SupraCoin).
    public entry fun deposit_reward_for_rate_growth_coins<RewardCoinType>(
        depositor: &signer,
        pool_creator_address: address,
        stake_addr: address,
        amount: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        // 1. Withdraw original Coin
        let reward_coin = coin::withdraw<RewardCoinType>(depositor, amount);

        // 2. Wrap into a Fungible Asset (FA)
        let reward_fa = coin_wrapper::wrap<RewardCoinType>(reward_coin);

        // 3. Get the wrapped FA address to build the pool key
        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj);

        // 4. Deposit into the user's primary store (so stake_fa can withdraw it)
        let depositor_addr = signer::address_of(depositor);
        if (!primary_fungible_store::primary_store_exists(depositor_addr, reward_metadata_obj)) {
            primary_fungible_store::create_primary_store(depositor_addr, reward_metadata_obj);
        };
        primary_fungible_store::deposit(depositor_addr, reward_fa);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        // 5. Call the core logic
        stake_fa::deposit_reward_for_rate_growth(depositor, pool_key, amount);
    }

    // [NEW] Entry point to renew a finished pool using Fungible Asset directly.
    public entry fun renew_pool_fa(
        depositor: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        amount: u64,
        new_duration: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::renew_pool(depositor, pool_key, amount, new_duration);
    }

    // [NEW] Entry point to renew a finished pool using Coins.
    public entry fun renew_pool_coins<RewardCoinType>(
        depositor: &signer,
        pool_creator_address: address,
        stake_addr: address,
        amount: u64,
        new_duration: u64
    ) {
        let stake_addr = get_canonical_address(stake_addr);

        // 1. Withdraw original Coin
        let reward_coin = coin::withdraw<RewardCoinType>(depositor, amount);

        // 2. Wrap into a Fungible Asset (FA)
        let reward_fa = coin_wrapper::wrap<RewardCoinType>(reward_coin);

        // 3. Get the wrapped FA address
        let reward_metadata_obj = coin_wrapper::create_fungible_asset<RewardCoinType>();
        let reward_addr = object::object_address(&reward_metadata_obj);

        // 4. Deposit into the user's primary store
        let depositor_addr = signer::address_of(depositor);
        if (!primary_fungible_store::primary_store_exists(depositor_addr, reward_metadata_obj)) {
            primary_fungible_store::create_primary_store(depositor_addr, reward_metadata_obj);
        };
        primary_fungible_store::deposit(depositor_addr, reward_fa);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        // 5. Call the core logic
        stake_fa::renew_pool(depositor, pool_key, amount, new_duration);
    }

    public entry fun boost(
        user: &signer,
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64,
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let token_id = token::create_token_id_raw(collection_owner, collection_name, token_name, property_version);
        let nft = token::withdraw_token(user, token_id, 1);
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::boost(user, pool_key, nft);
    }

    public entry fun remove_boost(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let nft = stake_fa::remove_boost(user, pool_key);
        token::deposit_token(user, nft);
    }

    public entry fun enable_emergency(
        admin: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::enable_emergency(admin, pool_key);
    }

    public entry fun disable_emergency(
        admin: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        stake_fa::disable_emergency(admin, pool_key);
    }

    public entry fun emergency_unstake(
        user: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
    ) {
        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);
        
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let user_addr = signer::address_of(user);

        let (_, fa_option, nft_option) = stake_fa::emergency_unstake(user, pool_key);
       
        if (option::is_some(&fa_option)) {
            let unstaked_fa = option::extract(&mut fa_option);

            ensure_primary_store_for_address(user_addr, stake_addr);

            primary_fungible_store::deposit(user_addr, unstaked_fa);

        };
        option::destroy_none(fa_option);

        if (option::is_some(&nft_option)) {
            token::deposit_token(user, option::extract(&mut nft_option));
        };
        option::destroy_none(nft_option);
    }

    public entry fun emergency_unstake_fa_coin<StakeCoinType>(
        user: &signer,
        pool_creator_address: address,
        reward_addr: address,
    ) {
        let reward_addr = get_canonical_address(reward_addr);

        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let user_addr = signer::address_of(user);
        let (_amount, fa_option, nft_option) = stake_fa::emergency_unstake(user, pool_key);

        if (option::is_some(&fa_option)) {
            let unstaked_fa = option::extract(&mut fa_option);
            let unstaked_coin = coin_wrapper::unwrap<StakeCoinType>(unstaked_fa);
            coin::deposit(user_addr, unstaked_coin);
        };
        option::destroy_none(fa_option);

        if (option::is_some(&nft_option)) {
            token::deposit_token(user, option::extract(&mut nft_option));
        };
        option::destroy_none(nft_option);
    }

    public entry fun emergency_unstake_from_coins<StakeCoinType, RewardCoinType>(
        user: &signer,
        pool_creator_address: address
    ) {
        let user_addr = signer::address_of(user);
        let stake_addr = get_wrapped_fa_address<StakeCoinType>();
        let reward_addr = get_wrapped_fa_address<RewardCoinType>();

        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );

        let (_amount_unstaked, fa_option, nft_option) = stake_fa::emergency_unstake(user, pool_key);

        if (option::is_some(&fa_option)) {
            let unstaked_fa_wrapped = option::extract(&mut fa_option);
            let unstaked_coin_original = coin_wrapper::unwrap<StakeCoinType>(unstaked_fa_wrapped);
            coin::deposit(user_addr, unstaked_coin_original);
        };
        option::destroy_none(fa_option);

        if (option::is_some(&nft_option)) {
            let returned_nft = option::extract(&mut nft_option);
            token::deposit_token(user, returned_nft);
        };
        option::destroy_none(nft_option);
    }

    public entry fun withdraw_reward_to_treasury(
        treasury: &signer, 
        pool_creator_address: address,
        stake_addr: address,
        reward_addr: address,
        amount: u64
    ) {

        let stake_addr = get_canonical_address(stake_addr);
        let reward_addr = get_canonical_address(reward_addr);
        
        let pool_key = stake_fa::new_pool_identifier(
            pool_creator_address,
            stake_addr,
            reward_addr
        );
        let treasury_addr = signer::address_of(treasury);
        let reward_assets = stake_fa::withdraw_to_treasury(treasury, pool_key, amount);
        ensure_primary_store_for_address(treasury_addr, reward_addr);
        primary_fungible_store::deposit(treasury_addr, reward_assets);
    }

    #[view]
    public fun get_address_BWSUP(): address {
        let metadata = coin_wrapper::get_wrapper<SupraCoin>();
        object::object_address(&metadata)
    }

    #[view]
    public fun get_original_from_address(fa_address: address): String {
        let metadata_object = object::address_to_object<Metadata>(fa_address);
        coin_wrapper::get_original(metadata_object)
    }

}
