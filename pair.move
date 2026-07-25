module spike_amm::amm_pair {
  use std::bcs;
  use std::option;
  use std::signer;
  use std::string::{Self, String};
  use std::vector;
  use std::error;

  use supra_framework::event;
  use supra_framework::dispatchable_fungible_asset;
  use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, MintRef, BurnRef, TransferRef, Metadata};
  use supra_framework::object::{Self, Object, ConstructorRef};
  use supra_framework::primary_fungible_store;
  use supra_framework::timestamp;

  use spike_amm::amm_controller;

  use razor_libs::math;
  use razor_libs::fixedpoint64;
  use razor_libs::sort;
  use razor_libs::token_utils;
  use aptos_std::math64;
  use aptos_std::smart_table::{Self, SmartTable};

  friend spike_amm::amm_factory;
  friend spike_amm::amm_router;

  const MINIMUM_LIQUIDITY: u64 = 1000;
  const LP_TOKEN_DECIMALS: u8 = 8;

  const ERROR_IDENTICAL_ADDRESSES: u64 = 2;
  const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 5;
  const ERROR_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 6;
  const ERROR_LOCKED: u64 = 20;
  const ERROR_ZERO_AMOUNT: u64 = 21;
  const ERROR_INSUFFICIENT_LIQUIDITY_MINT: u64 = 22;
  const ERROR_INSUFFICIENT_LIQUIDITY_BURN: u64 = 23;
  const ERROR_K_ERROR: u64 = 24;
  const ERROR_INVALID_TOKEN: u64 = 25;
  const ERROR_INSUFFICIENT_REPAYMENT: u64 = 26;
  const ERROR_WRONG_TOKEN: u64 = 27;
  const ERROR_WRONG_RECEIPT: u64 = 28;
  
  struct LPTokenRefs has store {
    burn_ref: BurnRef,
    mint_ref: MintRef,
    transfer_ref: TransferRef,
  }

  struct FlashLoanReceipt {
    amount_loaned: u64,
    fee: u64,
    token_borrowed: Object<Metadata>
  }

  struct FlashLoanRecord has store, drop {
    amount_loaned: u64,
    token_borrowed: Object<Metadata>
  }

  struct FlashLoanState has key {
    active_loans: SmartTable<address, FlashLoanRecord>
  }

  #[resource_group_member(group = supra_framework::object::ObjectGroup)]
  struct Pair has key {
    token0: Object<FungibleStore>,
    token1: Object<FungibleStore>,
    lp_token_refs: LPTokenRefs,
    block_timestamp_last: u64,
    price_0_cumulative_last: u128,
    price_1_cumulative_last: u128,
    k_last: u128,
    locked: bool,
  }

  #[event]
  struct MintEvent has drop, store {
    pair: address,
    sender: address,
    to: address,
    lp_amount: u64,
    amount0: u64,
    amount1: u64
  }

  #[event]
  struct MintFeeEvent has drop, store {
    pair: address,
    to: address,
    fee_amount: u64,
  }

  #[event]
  struct BurnEvent has drop, store {
    pair: address,
    sender: address,
    lp_amount: u64,
    amount0: u64,
    amount1: u64,
  }

  #[event]
  struct SwapEvent has drop, store {
    sender: address,
    amount0_in: u64,
    amount1_in: u64,
    amount0_out: u64,
    amount1_out: u64,
    pair_address: address,
    to: address,
  }

  #[event]
  struct SyncEvent has drop, store {
    reserve0: u128,
    reserve1: u128,
    pair_address: address,
  }

  #[event]
  struct FlashLoanEvent has drop, store {
      borrower: address,
      token: address,
      amount: u64,
      fee_amount: u64
  }

  inline fun lock_pair(lp: &mut Pair) {
    assert!(lp.locked == false, error::permission_denied(ERROR_LOCKED));
    lp.locked = true;
  }

  inline fun unlock_pair(lp: &mut Pair) {
      lp.locked = false;
  }

  public(friend) fun lock_launchpad_pair(pair: &Object<Pair>) acquires Pair {
      let lp = pair_data_mut(pair);
      assert!(!lp.locked, error::invalid_state(ERROR_LOCKED));
      lp.locked = true;
  }

  public(friend) fun unlock_launchpad_pair(pair: &Object<Pair>) acquires Pair {
      let lp = pair_data_mut(pair);
      assert!(lp.locked, error::invalid_state(ERROR_LOCKED)); 
      lp.locked = false;
  }

  public fun flash_loan(
      pair: Object<Pair>,
      token_to_borrow: Object<Metadata>,
      amount: u64
  ): (FungibleAsset, FlashLoanReceipt) acquires Pair, FlashLoanState {
      amm_controller::assert_unpaused();
      let lp_data = pair_data_mut(&pair);
      assert!(!lp_data.locked, error::permission_denied(ERROR_LOCKED));
      lp_data.locked = true; 

      let token0 = fungible_asset::store_metadata(lp_data.token0);
      let token1 = fungible_asset::store_metadata(lp_data.token1);

      assert!(
          token_to_borrow == token0 || token_to_borrow == token1, 
          error::invalid_argument(ERROR_INVALID_TOKEN)
      );

      let bps = amm_controller::get_flash_loan_fee_bps(); 
      let fee = ((((amount as u128) * (bps as u128)) / 10000) as u64);
      
      let store_to_withdraw_from = if (token_to_borrow == token0) {
          lp_data.token0
      } else {
          lp_data.token1
      };

      let swap_signer = &amm_controller::get_signer();
      let loan_asset = dispatchable_fungible_asset::withdraw(swap_signer, store_to_withdraw_from, amount);

      let receipt = FlashLoanReceipt {
          amount_loaned: amount,
          fee,
          token_borrowed: token_to_borrow
      };

      event::emit(FlashLoanEvent {
          borrower: std::signer::address_of(&amm_controller::get_signer()),
          token: object::object_address(&token_to_borrow),
          amount,
          fee_amount: fee
      });

      let pair_addr = object::object_address(&pair);
      let state = get_mut_flash_loan_state();
      smart_table::upsert(state, pair_addr, FlashLoanRecord {
          amount_loaned: amount,
          token_borrowed: token_to_borrow
      });

      (loan_asset, receipt)
  }

  public fun repay_flash_loan(
      pair: Object<Pair>,
      payment: FungibleAsset,
      receipt: FlashLoanReceipt
  ) acquires Pair, FlashLoanState {
      let FlashLoanReceipt { amount_loaned, fee, token_borrowed } = receipt;

      let lp = pair_data_mut(&pair);
      assert!(lp.locked, error::invalid_state(ERROR_LOCKED));

      let pair_addr = object::object_address(&pair);
      let state = get_mut_flash_loan_state();
      assert!(smart_table::contains(state, pair_addr), error::invalid_argument(ERROR_WRONG_RECEIPT));
      let record = smart_table::remove(state, pair_addr);
      assert!(record.amount_loaned == amount_loaned && record.token_borrowed == token_borrowed, error::invalid_argument(ERROR_WRONG_RECEIPT));

      let payment_amount = fungible_asset::amount(&payment);
      let required_amount = amount_loaned + fee;

      assert!(payment_amount >= required_amount, error::invalid_argument(ERROR_INSUFFICIENT_REPAYMENT));
      assert!(fungible_asset::asset_metadata(&payment) == token_borrowed, error::invalid_argument(ERROR_WRONG_TOKEN));

      let token0 = fungible_asset::store_metadata(lp.token0);
      let store_to_deposit = if (token_borrowed == token0) {
          lp.token0
      } else {
          lp.token1
      };

      dispatchable_fungible_asset::deposit(store_to_deposit, payment);
      
      lp.locked = false;
  }

  inline fun get_mut_flash_loan_state(): &mut SmartTable<address, FlashLoanRecord> {
    let amm_signer = amm_controller::get_signer();
    let amm_addr = signer::address_of(&amm_signer);
    if (!exists<FlashLoanState>(amm_addr)) {
      move_to(&amm_signer, FlashLoanState {
        active_loans: smart_table::new()
      });
    };
    &mut borrow_global_mut<FlashLoanState>(amm_addr).active_loans
  }

  fun assert_locked(pair: Object<Pair>) acquires Pair {
    let lp = pair_data(&pair);
    let locked = lp.locked;
    assert!(locked == false, error::permission_denied(ERROR_LOCKED));
  }

  #[view]
  public fun get_reserves(pair: Object<Pair>): (u64, u64, u64) acquires Pair {
    let pair_data = pair_data(&pair);
    (
      fungible_asset::balance(pair_data.token0),
      fungible_asset::balance(pair_data.token1),
      pair_data.block_timestamp_last,
    )
  }

  #[view]
  public fun get_k_last(pair: Object<Pair>): u128 acquires Pair {
    let pair_data = pair_data(&pair);
    pair_data.k_last
  }

  #[view]
  public fun get_cumulative_prices(pair: Object<Pair>): (u128, u128) acquires Pair {
    let pair_data = pair_data(&pair);
    (pair_data.price_0_cumulative_last, pair_data.price_1_cumulative_last)
  }

  #[view]
  public fun price_0_cumulative_last(pair: Object<Pair>): u128 acquires Pair {
    let pair_data = pair_data(&pair);
    pair_data.price_0_cumulative_last
  }

  #[view]
  public fun price_1_cumulative_last(pair: Object<Pair>): u128 acquires Pair {
    let pair_data = pair_data(&pair);
    pair_data.price_1_cumulative_last
  }

  #[view]
  public fun balance0(pair: Object<Pair>): u64 acquires Pair {
    let pair_data = pair_data(&pair);
    fungible_asset::balance(pair_data.token0)
  }

  #[view]
  public fun balance1(pair: Object<Pair>): u64 acquires Pair {
    let pair_data = pair_data(&pair);
    fungible_asset::balance(pair_data.token1)
  }

  #[view]
  public fun token0(pair: Object<Pair>): Object<Metadata> acquires Pair {
    let pair_data = pair_data(&pair);
    fungible_asset::store_metadata(pair_data.token0)
  }

  #[view]
  public fun token1(pair: Object<Pair>): Object<Metadata> acquires Pair {
    let pair_data = pair_data(&pair);
    fungible_asset::store_metadata(pair_data.token1)
  }

  #[view]
  public fun balance_of(pair: Object<Pair>, token: Object<Metadata>): u64 acquires Pair {
    let pair_data = pair_data(&pair);
    let token0_meta = fungible_asset::store_metadata(pair_data.token0);
    let token1_meta = fungible_asset::store_metadata(pair_data.token1);

    if (token == token0_meta) {
      fungible_asset::balance(pair_data.token0)
    } else if (token == token1_meta) {
      fungible_asset::balance(pair_data.token1)
    } else {
      0
    }
  }

  public(friend) fun initialize(
    token0: Object<Metadata>,
    token1: Object<Metadata>,
  ): Object<Pair> {
    if (!sort::is_sorted_two(token0, token1)) {
      return initialize(token1, token0)
    };

    let pair_constructor_ref = create_lp_token(token0, token1);
    let pair_signer = &object::generate_signer(pair_constructor_ref);
    let lp_token = object::object_from_constructor_ref<Metadata>(pair_constructor_ref);
    fungible_asset::create_store(pair_constructor_ref, lp_token);
    move_to(pair_signer, Pair {
      token0: create_token_store(pair_signer, token0),
      token1: create_token_store(pair_signer, token1),
      lp_token_refs: create_lp_token_refs(pair_constructor_ref),
      block_timestamp_last: 0,
      price_0_cumulative_last: 0,
      price_1_cumulative_last: 0,
      k_last: 0,
      locked: false,
    });

    let pair = object::convert(lp_token);

    pair
  }

  #[view]
  public fun unpack_pair(pair: Object<Pair>): (Object<Metadata>, Object<Metadata>) acquires Pair {
    let pair = pair_data(&pair);
    let token0 = fungible_asset::store_metadata(pair.token0);
    let token1 = fungible_asset::store_metadata(pair.token1);

    if (sort::is_sorted_two(token0, token1)) {
      (token0, token1)
    } else {
      (token1, token0)
    }
  }

  inline fun update(
    lp: &mut Pair,
    balance0: u64,
    balance1: u64,
    reserve0: u64,
    reserve1: u64
  ) {
    let now = timestamp::now_seconds();
    let time_elapsed = ((now - lp.block_timestamp_last) as u128);
    if (time_elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
      let price_0_cumulative_last_delta = fixedpoint64::to_u128(fixedpoint64::fraction(reserve1, reserve0)) * time_elapsed;
      lp.price_0_cumulative_last = math::overflow_add(lp.price_0_cumulative_last, price_0_cumulative_last_delta);

      let price_1_cumulative_last_delta = fixedpoint64::to_u128(fixedpoint64::fraction(reserve0, reserve1)) * time_elapsed;
      lp.price_1_cumulative_last = math::overflow_add(lp.price_1_cumulative_last, price_1_cumulative_last_delta);
    };
    lp.block_timestamp_last = now;

    let token0_metadata = fungible_asset::store_metadata(lp.token0);
    let token1_metadata = fungible_asset::store_metadata(lp.token1);

    event::emit(SyncEvent {
      reserve0: (balance0 as u128),
      reserve1: (balance1 as u128),
      pair_address: liquidity_pool_address(token0_metadata, token1_metadata),
    })
  }

  #[view]
  public fun lp_token_supply(pair: Object<Pair>): u128 {
    option::destroy_some(fungible_asset::supply(pair))
  }

  #[view]
  public fun lp_balance_of(account: address, pair: Object<Pair>): u64 {
    primary_fungible_store::balance(account, pair)
  }

  inline fun mint_fee(
    pair: Object<Pair>,
  ): bool acquires Pair {
    let lp_address = object::object_address(&pair);
    let lp = pair_data_mut(&pair);
    let fee_on = amm_controller::get_fee_on();
    let fee_to = amm_controller::get_fee_to();
    let k_last = lp.k_last;
    if (fee_on) {
      if (k_last != 0) {
        let reserve0 = fungible_asset::balance(lp.token0);
        let reserve1 = fungible_asset::balance(lp.token1);
        let root_k = math::sqrt(reserve0, reserve1);
        let root_k_last = math::sqrt_128(k_last);
        let total_supply = lp_token_supply(pair);
        if (root_k > root_k_last) {
          let delta_k = ((root_k - root_k_last) as u128);
          if (math::is_overflow_mul(total_supply, delta_k)) {
            let numerator = (total_supply as u256) * (delta_k as u256) * (10);
            let denominator = (root_k as u256) * (20) + (root_k_last as u256);
            let liquidity = ((numerator / denominator) as u64);
            if (liquidity > 0) {
              mint_internal(pair, fee_to, liquidity);
              event::emit(MintFeeEvent {
                pair: lp_address,
                to: fee_to,
                fee_amount: liquidity,
              });
            };
          } else {
            let numerator = total_supply * delta_k * 10;
            let denominator = (root_k as u128) * (20) + (root_k_last as u128);
            let liquidity = ((numerator / denominator) as u64);
            if (liquidity > 0) {
              mint_internal(pair, fee_to, liquidity);
              event::emit(MintFeeEvent {
                pair: lp_address,
                to: fee_to,
                fee_amount: liquidity,
              });
            };
          };
        }
      }
    } else if (k_last != 0) {
      lp.k_last = 0;
    };

    fee_on
  }

  inline fun mint_internal(
    pair: Object<Pair>,
    to: address,
    amount: u64,
  ) acquires Pair {
    let pair_data = pair_data(&pair);
    primary_fungible_store::ensure_primary_store_exists(to, pair);
    let acc_store = primary_fungible_store::primary_store(to, pair);
    let mint_ref = &pair_data.lp_token_refs.mint_ref;
    let transfer_ref = &pair_data.lp_token_refs.transfer_ref;
    let lp_coins = fungible_asset::mint(mint_ref, amount);
    fungible_asset::deposit_with_ref(transfer_ref, acc_store, lp_coins);
  }

  public(friend) fun mint(
    sender: &signer,
    fungible_token0: FungibleAsset,
    fungible_token1: FungibleAsset,
    to: address,
  ): (u64, Object<Metadata>) acquires Pair {
    let sender_address = signer::address_of(sender);
    let token0 = fungible_asset::metadata_from_asset(&fungible_token0);
    let token1 = fungible_asset::metadata_from_asset(&fungible_token1);
    if (!sort::is_sorted_two(token0, token1)) {
      return mint(sender, fungible_token1, fungible_token0, to)
    };

    let pool = liquidity_pool(token0, token1);
    amm_controller::assert_unpaused();
    let lp_data = pair_data(&pool);
    assert!(!lp_data.locked, error::permission_denied(ERROR_LOCKED));

    primary_fungible_store::ensure_primary_store_exists(to, pool);
    let acc_store = primary_fungible_store::primary_store(to, pool);

    let fee_on = mint_fee(pool);

    let lp = pair_data_mut(&pool);
    lock_pair(lp);
    let reserve0 = fungible_asset::balance(lp.token0);
    let reserve1 = fungible_asset::balance(lp.token1);

    dispatchable_fungible_asset::deposit(lp.token0, fungible_token0);
    dispatchable_fungible_asset::deposit(lp.token1, fungible_token1);

    let amount0 = fungible_asset::balance(lp.token0) - reserve0;
    let amount1 = fungible_asset::balance(lp.token1) - reserve1;

    let total_supply = option::destroy_some(fungible_asset::supply(pool));
    let mint_ref = &lp.lp_token_refs.mint_ref;
    let liquidity;
    if (total_supply == 0) {
      assert!(math::sqrt(amount0, amount1) > MINIMUM_LIQUIDITY, error::invalid_argument(ERROR_INSUFFICIENT_LIQUIDITY_MINT));

      liquidity = math::sqrt(amount0, amount1) - MINIMUM_LIQUIDITY;
      primary_fungible_store::mint(mint_ref, @spike_amm, MINIMUM_LIQUIDITY);
    } else {
      assert!(reserve0 > 0 && reserve1 > 0, error::invalid_state(ERROR_ZERO_AMOUNT));
      let t_amount0 = ((amount0 as u128) * total_supply / (reserve0 as u128) as u64);
      let t_amount1 = ((amount1 as u128) * total_supply / (reserve1 as u128) as u64);
      liquidity = math64::min(t_amount0, t_amount1);
    };
    assert!(liquidity > 0, error::invalid_argument(ERROR_INSUFFICIENT_LIQUIDITY_MINT));

    let lp_coins = fungible_asset::mint(mint_ref, liquidity);

    let lp_amount = fungible_asset::amount(&lp_coins);
    fungible_asset::deposit_with_ref(&lp.lp_token_refs.transfer_ref, acc_store, lp_coins);

    let balance0 = fungible_asset::balance(lp.token0);
    let balance1 = fungible_asset::balance(lp.token1);
    update(lp, balance0, balance1, reserve0, reserve1);
    if (fee_on) lp.k_last = (balance0 as u128) * (balance1 as u128);

    let lp_token_metadata = object::address_to_object<Metadata>(object::object_address(&pool));
    let pair_address = liquidity_pool_address(token0, token1);

    event::emit(MintEvent {
      pair: pair_address,
      lp_amount,
      sender: sender_address,
      amount0,
      amount1,
      to
    });
    unlock_pair(lp);
    (lp_amount, lp_token_metadata)
  }

  public(friend) fun burn(
    sender: &signer,
    pair: Object<Pair>,
    amount: u64,
  ): (FungibleAsset, FungibleAsset) acquires Pair {
    let lp_data = pair_data(&pair);
    assert!(!lp_data.locked, error::permission_denied(ERROR_LOCKED));
    assert!(amount > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));
    let sender_addr = signer::address_of(sender);
    primary_fungible_store::ensure_primary_store_exists(sender_addr, pair);
    let store = primary_fungible_store::primary_store(sender_addr, pair);

    let fee_on = mint_fee(pair);

    let lp = pair_data_mut(&pair);
    lock_pair(lp);
    let store0 = lp.token0;
    let store1 = lp.token1;
    let reserve0 = fungible_asset::balance(store0);
    let reserve1 = fungible_asset::balance(store1);

    let total_supply = lp_token_supply(pair);
    assert!(total_supply > 0, error::invalid_state(ERROR_INSUFFICIENT_LIQUIDITY_BURN));
    let amount0 = ((amount as u128) * (reserve0 as u128) / total_supply as u64);
    let amount1 = ((amount as u128) * (reserve1 as u128) / total_supply as u64);

    assert!(amount0 > 0 && amount1 > 0, error::invalid_state(ERROR_INSUFFICIENT_LIQUIDITY_BURN));

    let swap_signer = &amm_controller::get_signer();

    fungible_asset::burn_from(&lp.lp_token_refs.burn_ref, store, amount);

    let redeemed0 = dispatchable_fungible_asset::withdraw(swap_signer, store0, amount0);
    let redeemed1 = dispatchable_fungible_asset::withdraw(swap_signer, store1, amount1);
    
    let balance0 = fungible_asset::balance(store0); 
    let balance1 = fungible_asset::balance(store1);
    
    update(lp, balance0, balance1, reserve0, reserve1);
    if (fee_on) lp.k_last = (balance0 as u128) * (balance1 as u128);

    let token0 = fungible_asset::metadata_from_asset(&redeemed0);
    let token1 = fungible_asset::metadata_from_asset(&redeemed1);

    event::emit(BurnEvent {
      pair: liquidity_pool_address(token0, token1),
      sender: sender_addr,
      amount0: amount0,
      amount1: amount1,
      lp_amount: amount,
    });
    unlock_pair(lp);
    if (sort::is_sorted_two(fungible_asset::store_metadata(lp.token0), fungible_asset::store_metadata(lp.token1))) {
      (redeemed0, redeemed1)
    } else {
      (redeemed1, redeemed0)
    }
  }

  public(friend) fun swap(
    sender: &signer,
    pair: Object<Pair>,
    token0_in: FungibleAsset,
    amount0_out: u64,
    token1_in: FungibleAsset,
    amount1_out: u64,
    to: address,
  ): (FungibleAsset, FungibleAsset) acquires Pair {
    amm_controller::assert_unpaused();
    let lp_data = pair_data(&pair);
    assert!(!lp_data.locked, error::permission_denied(ERROR_LOCKED));
    let declared_amount0_in = fungible_asset::amount(&token0_in);
    let declared_amount1_in = fungible_asset::amount(&token1_in);

    assert!(declared_amount0_in > 0 || declared_amount1_in > 0, error::invalid_argument(ERROR_INSUFFICIENT_INPUT_AMOUNT));
    assert!(amount0_out > 0 || amount1_out > 0, error::invalid_argument(ERROR_INSUFFICIENT_OUTPUT_AMOUNT));

    let lp = pair_data_mut(&pair);
    lock_pair(lp);
    let store0 = lp.token0;
    let store1 = lp.token1;
    let reserve0 = fungible_asset::balance(store0);
    let reserve1 = fungible_asset::balance(store1);

    if (declared_amount0_in > 0) {
        dispatchable_fungible_asset::deposit(store0, token0_in);
    } else {
        fungible_asset::destroy_zero(token0_in);
    };

    if (declared_amount1_in > 0) {
        dispatchable_fungible_asset::deposit(store1, token1_in);
    } else {
        fungible_asset::destroy_zero(token1_in);
    };

    let swap_signer = &amm_controller::get_signer();

    let token0_out = dispatchable_fungible_asset::withdraw(swap_signer, store0, amount0_out);
    let token1_out = dispatchable_fungible_asset::withdraw(swap_signer, store1, amount1_out);

    let balance0 = fungible_asset::balance(store0);
    let balance1 = fungible_asset::balance(store1);
    let actual_amount0_in = if (balance0 > reserve0 - amount0_out) {
        balance0 - (reserve0 - amount0_out)
    } else {
        0
    };
    
    let actual_amount1_in = if (balance1 > reserve1 - amount1_out) {
        balance1 - (reserve1 - amount1_out)
    } else {
        0
    };

    let swap_fee = amm_controller::get_swap_fee();

    assert_k_increase(balance0, balance1, actual_amount0_in, actual_amount1_in, reserve0, reserve1, swap_fee);
    update(lp, balance0, balance1, reserve0, reserve1);

    let pair_address = liquidity_pool_address(fungible_asset::store_metadata(lp.token0), fungible_asset::store_metadata(lp.token1));
    
    event::emit(SwapEvent {
      sender: signer::address_of(sender),
      amount0_in: actual_amount0_in,
      amount1_in: actual_amount1_in,
      amount0_out,
      amount1_out,
      pair_address: pair_address,
      to,
    });
    unlock_pair(lp);
    (token0_out, token1_out)
  }

  inline fun assert_k_increase(
    balance0: u64,
    balance1: u64,
    amount0_in: u64,
    amount1_in: u64,
    reserve0: u64,
    reserve1: u64,
    swap_fee: u8,
  ) {
    let balance0_adjusted = (balance0 as u128) * 10000 - (amount0_in as u128) * (swap_fee as u128);
    let balance1_adjusted = (balance1 as u128) * 10000 - (amount1_in as u128) * (swap_fee as u128);
    let balance01_old_not_scaled = (reserve0 as u128) * (reserve1 as u128);
    let scale = 100000000;
    if (
      math::is_overflow_mul(balance0_adjusted, balance1_adjusted)
      || math::is_overflow_mul(balance01_old_not_scaled, scale)
    ) {
      let balance01_adjusted = ((balance0_adjusted as u256) * (balance1_adjusted as u256));
      let balance01_old = ((balance01_old_not_scaled as u256) * (scale as u256));
      assert!(balance01_adjusted >= balance01_old, error::invalid_state(ERROR_K_ERROR));

    } else {
      assert!(balance0_adjusted * balance1_adjusted >= balance01_old_not_scaled * scale, error::invalid_state(ERROR_K_ERROR));
    };
  }

  #[view]
  public fun liquidity_pool(
    token0: Object<Metadata>,
    token1: Object<Metadata>,
  ): Object<Pair> {
    object::address_to_object(liquidity_pool_address(token0, token1))
  }

  #[view]
  public fun liquidity_pool_address_safe(
    token0: Object<Metadata>,
    token1: Object<Metadata>,
  ): (bool, address) {
    let pool_address = liquidity_pool_address(token0, token1);
    (exists<Pair>(pool_address), pool_address)
  }

  #[view]
  public fun liquidity_pool_address(
    token0: Object<Metadata>,
    token1: Object<Metadata>
  ): address {
    if (!sort::is_sorted_two(token0, token1)) {
      return liquidity_pool_address(token1, token0)
    };

    let seed = get_pair_seed(token0, token1);
    object::create_object_address(&amm_controller::get_signer_address(), seed)
  }

  public inline fun pair_data<T: key>(pair: &Object<T>): &Pair acquires Pair {
    borrow_global<Pair>(object::object_address(pair))
  }

  inline fun pair_data_mut<T: key>(pair: &Object<T>): &mut Pair acquires Pair {
    borrow_global_mut<Pair>(object::object_address(pair))
  }

  inline fun create_lp_token(
    token0: Object<Metadata>,
    token1: Object<Metadata>,
  ): &ConstructorRef {
    let token_name = lp_token_name(token0, token1);
    
    if (string::length(&token_name) > 32) {
      token_name = string::sub_string(&token_name, 0, 32);
    };

    let seed = get_pair_seed(token0, token1);
    let lp_token_constructor_ref = &object::create_named_object(&amm_controller::get_signer(), seed);
    primary_fungible_store::create_primary_store_enabled_fungible_asset(
      lp_token_constructor_ref,
      option::none(),
      token_name,
      string::utf8(b"POOL-LP"),
      LP_TOKEN_DECIMALS,
      string::utf8(b"ipfs://bafkreiah6qff4lzwupmjkqmdb4bzhj3oiywvcnwqi3um34ayzbvhwvvfa4"),
      string::utf8(b"https://hoglet.xyz"),
    );

    lp_token_constructor_ref
  }

  inline fun lp_token_name(token0: Object<Metadata>, token1: Object<Metadata>): String {
    let token_symbol = string::utf8(b"Pool ");
    string::append(&mut token_symbol, fungible_asset::symbol(token0));
    string::append_utf8(&mut token_symbol, b"-");
    string::append(&mut token_symbol, fungible_asset::symbol(token1));
    string::append_utf8(&mut token_symbol, b" LP");
    token_symbol
  }

  public inline fun get_pair_seed(token0: Object<Metadata>, token1: Object<Metadata>): vector<u8> {
    let (tokenA, tokenB) = sort::sort_two_tokens(token0, token1);
    let seeds = vector[];
    vector::append(&mut seeds, bcs::to_bytes(&object::object_address(&tokenA)));
    vector::append(&mut seeds, bcs::to_bytes(&object::object_address(&tokenB)));
    seeds
  }

  inline fun create_token_store(pair_signer: &signer, token: Object<Metadata>): Object<FungibleStore> {
    let constructor_ref = &object::create_object_from_object(pair_signer);
    fungible_asset::create_store(constructor_ref, token)
  }

  fun create_lp_token_refs(constructor_ref: &ConstructorRef): LPTokenRefs {
    LPTokenRefs {
      burn_ref: fungible_asset::generate_burn_ref(constructor_ref),
      mint_ref: fungible_asset::generate_mint_ref(constructor_ref),
      transfer_ref: fungible_asset::generate_transfer_ref(constructor_ref),
    }
  }
}