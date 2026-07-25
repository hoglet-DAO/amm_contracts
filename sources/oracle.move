module spike_amm::amm_oracle {
  use std::signer;
  use std::error;
  
  use supra_framework::block;
  use supra_framework::event;
  use supra_framework::fungible_asset::{Self, Metadata};
  use supra_framework::object::{Self, Object};
  use supra_framework::timestamp;

  use aptos_std::math64;
  use aptos_std::simple_map::{Self, SimpleMap};
  use aptos_std::smart_vector::{Self, SmartVector};

  use spike_amm::amm_controller;
  use spike_amm::amm_factory;
  use spike_amm::oracle_library;
  use spike_amm::amm_pair::{Self, Pair};

  use razor_libs::sort;

  const MAX_U64: u64 = 18446744073709551615;
  const MAX_U128: u128 = 340282366920938463463374607431768211455;

  const ERROR_ONLY_ADMIN: u64 = 1;
  const ERROR_INDEX_OUT_OF_BOUNDS: u64 = 2;
  const ERROR_TIME_ELAPSED_ZERO: u64 = 3;
  const ERROR_PRICE_CUMULATIVE_END_LESS_THAN_START: u64 = 4;
  const ERROR_AMOUNT_OUT_OVERFLOW: u64 = 5;
  const ERROR_HEIGHT_DIFF_ZERO: u64 = 6;
  const ERROR_TOKEN_NOT_FOUND: u64 = 7;
  const ERROR_ROUTER_LIST_FULL: u64 = 8;
  const ERROR_PRICE_CALCULATION_OVERFLOW: u64 = 9;
  const MAX_ROUTER_TOKENS: u64 = 20;

  struct Observation has copy, drop, store {
    timestamp: u64,
    price_0_cumulative: u128,
    price_1_cumulative: u128,
  }

  struct BlockInfo has copy, drop, store {
    height: u64,
    timestamp: u64,
  }

  struct Oracle has key {
    anchor_token: Object<Metadata>,
    block_info: BlockInfo,
    pair_observations: SimpleMap<Object<Pair>, Observation>,
    router_tokens: SmartVector<Object<Metadata>>,
  }

  #[event]
  struct UpdateEvent has drop, store {
    pair: address,
    price_0_cumulative: u128,
    price_1_cumulative: u128,
    timestamp: u64,
  }

  #[event]
  struct RouterTokenEvent has drop, store {
    token: address,
    is_added: bool,
  }

  const CYCLE: u64 = 1800;

  public entry fun initialize(sender: &signer, anchor_token: Object<Metadata>) {
    assert!(signer::address_of(sender) == amm_controller::get_admin(), error::permission_denied(ERROR_ONLY_ADMIN));
    if (is_initialized()) {
        return
    };
    let swap_signer = &amm_controller::get_signer();
    move_to(swap_signer, Oracle {
        anchor_token: anchor_token,
        block_info: BlockInfo {
            height: block::get_current_block_height(),
            timestamp: timestamp::now_seconds(),
        },
        pair_observations: simple_map::new<Object<Pair>, Observation>(),
        router_tokens: smart_vector::new<Object<Metadata>>(),
    });
  }

  #[view]
  public fun is_initialized(): bool {
    let signer_address = amm_controller::get_signer_address();
    exists<Oracle>(signer_address)
  }

  public fun update(tokenA: Object<Metadata>, tokenB: Object<Metadata>): bool acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let pair = amm_pair::liquidity_pool(tokenA, tokenB);
    if (!amm_factory::pair_exists(tokenA, tokenB)) {
      return false
    };

    let oracle_mut = borrow_global_mut<Oracle>(signer_address);
    let pair_observations = &mut oracle_mut.pair_observations;

    if (!simple_map::contains_key(pair_observations, &pair)) {
        simple_map::add(pair_observations, pair, Observation {
            timestamp: timestamp::now_seconds(),
            price_0_cumulative: 0,
            price_1_cumulative: 0,
        });
        return true
    };

    let observation = simple_map::borrow_mut(pair_observations, &pair);
    let time_elapsed = timestamp::now_seconds() - observation.timestamp;
    if (time_elapsed < CYCLE) {
      return false
    };

    let (price_0_cumulative, price_1_cumulative, _) = oracle_library::current_cumulative_prices(pair);

    observation.price_0_cumulative = price_0_cumulative;
    observation.price_1_cumulative = price_1_cumulative;
    observation.timestamp = timestamp::now_seconds();
    
    event::emit(UpdateEvent {
      pair: object::object_address(&pair),
      price_0_cumulative: observation.price_0_cumulative,
      price_1_cumulative: observation.price_1_cumulative,
      timestamp: observation.timestamp,
    });
    
    true
  }

  public fun update_block_info(): bool acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let block_info = &mut borrow_global_mut<Oracle>(signer_address).block_info;

    if ((block::get_current_block_height() - block_info.height) < 1000) {
      return false
    };

    block_info.height = block::get_current_block_height();
    block_info.timestamp = timestamp::now_seconds();
    true
  }

  // @deprecated Internal legacy function. Prone to overflow when the calculated amount exceeds the u64 limit.
  // This function is kept for historical reference but should not be used in new calculations.
  //
  // For all new logic, use `compute_amount_out_v2` which returns a `u128` for enhanced safety.

  fun compute_amount_out(
    price_cumulative_start: u128,
    price_cumulative_end: u128,
    time_elapsed: u64,
    amount_in: u64,
  ): u64 {
    assert!(time_elapsed > 0, error::invalid_state(ERROR_TIME_ELAPSED_ZERO));
    assert!(price_cumulative_end >= price_cumulative_start, error::invalid_state(ERROR_PRICE_CUMULATIVE_END_LESS_THAN_START));
    
    let price_delta = price_cumulative_end - price_cumulative_start;
    let amount_out = (amount_in as u128) * price_delta / (time_elapsed as u128);

    assert!((amount_out as u64) <= MAX_U64, error::invalid_state(ERROR_AMOUNT_OUT_OVERFLOW));

    (amount_out as u64)
  }

  fun compute_amount_out_v2(
    price_cumulative_start: u128,
    price_cumulative_end: u128,
    time_elapsed: u64,
    amount_in: u64,
  ): u128 {
    assert!(time_elapsed > 0, error::invalid_state(ERROR_TIME_ELAPSED_ZERO));
    assert!(price_cumulative_end >= price_cumulative_start, error::invalid_state(ERROR_PRICE_CUMULATIVE_END_LESS_THAN_START));
    
    let price_delta = price_cumulative_end - price_cumulative_start;
    let amount_out = (amount_in as u128) * price_delta / (time_elapsed as u128);

    amount_out
  }

  // @deprecated DEPRECATED. This function is highly susceptible to arithmetic overflow with large values.
  // Continued use may lead to transaction failures. It is strongly recommended to migrate to the `v2` version.
  //
  // For safe and reliable price consultations, please use `consult_v2`, which returns a `u128`
  // to handle larger cumulative price values without overflow.

  fun consult(
    token_in: Object<Metadata>,
    amount_in: u64,
    token_out: Object<Metadata>,
  ): u64  acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let pair = amm_pair::liquidity_pool(token_in, token_out);
    if (!amm_factory::pair_exists(token_in, token_out)) {
      return 0
    };

    let oracle = borrow_global<Oracle>(signer_address);
    let pair_observations = &oracle.pair_observations;
    let (price_0_cumulative, price_1_cumulative, _) = oracle_library::current_cumulative_prices(pair);

    let observation = simple_map::borrow(pair_observations, &pair);
    let time_elapsed = timestamp::now_seconds() - observation.timestamp;
    
    let (token0, _) = sort::sort_two_tokens(token_in, token_out);

    if (token0 == token_in) {
      return compute_amount_out(observation.price_0_cumulative, price_0_cumulative, time_elapsed, amount_in)
    } else {
      return compute_amount_out(observation.price_1_cumulative, price_1_cumulative, time_elapsed, amount_in)
    }
  }

  fun consult_v2(
    token_in: Object<Metadata>,
    token_out: Object<Metadata>,
): u128 acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let pair = amm_pair::liquidity_pool(token_in, token_out);
    if (!amm_factory::pair_exists(token_in, token_out)) {
      return 0
    };

    let oracle = borrow_global<Oracle>(signer_address);
    let pair_observations = &oracle.pair_observations;
    let (price_0_cumulative, price_1_cumulative, _) = oracle_library::current_cumulative_prices(pair);

    let observation = simple_map::borrow(pair_observations, &pair);
    let time_elapsed = timestamp::now_seconds() - observation.timestamp;
    
    let (token0, _) = sort::sort_two_tokens(token_in, token_out);
    
    let price_delta = if (token0 == token_in) {
      price_0_cumulative - observation.price_0_cumulative
    } else {
      price_1_cumulative - observation.price_1_cumulative
    };

    assert!(time_elapsed > 0, ERROR_TIME_ELAPSED_ZERO);
    price_delta / (time_elapsed as u128)
}


  // @deprecated DEPRECATED. This function may produce inaccurate results or fail due to overflow.
  // It returns a `u64`, which may be insufficient for representing the value of tokens with high prices or large amounts.
  //
  // Please use the safer `get_quantity_v2`, which leverages a `u128` return type for greater precision and safety.

  #[view]
  public fun get_quantity(token: Object<Metadata>, amount: u64): u64 acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let decimal = fungible_asset::decimals(token);
    let anchor_token = borrow_global<Oracle>(signer_address).anchor_token;
    let quantity;
    if (token == anchor_token) {
      quantity = amount
    } else {
      quantity = (get_average_price(token) as u64) * amount / math64::pow(10, (decimal as u64))
    };

    (quantity as u64)
  }

  #[view]
  public fun get_quantity_v2(token: Object<Metadata>, amount: u64): u128 acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let decimal = fungible_asset::decimals(token);
    let anchor_token = borrow_global<Oracle>(signer_address).anchor_token;
    let quantity;
    if (token == anchor_token) {
      quantity = (amount as u128)
    } else {
      quantity = get_average_price_v2(token) * (amount as u128) / (math64::pow(10, (decimal as u64)) as u128)
    };

    quantity
  }

  // @deprecated LEGACY VIEW FUNCTION. Prone to overflow errors during intermediate calculations.
  // This function relies on other deprecated `v1` methods, making it unsafe for pairs with significant liquidity or price.
  // While it returns a `u128`, its internal logic can still fail.
  //
  // For reliable and safe price discovery, please use the fully upgraded `get_average_price_v2`.

  #[view]
  public fun get_average_price(token: Object<Metadata>): u128 acquires Oracle  {
      let decimal = fungible_asset::decimals(token);
      let amount = math64::pow(10, (decimal as u64));

      let signer_address = amm_controller::get_signer_address();
      let oracle_state = borrow_global<Oracle>(signer_address);
      let anchor_token = oracle_state.anchor_token;

      if (token == anchor_token) {
          return (amount as u128)
      };
      
      if (amm_factory::pair_exists(token, anchor_token)) {
          return (consult(token, amount, anchor_token) as u128)
      };


      let best_price: u128 = 0;
      let highest_path_liquidity: u64 = 0;

      let length = get_router_token_length();
      let i = 0;
      while (i < length) {
          let intermediate = get_router_token(i);
          if (amm_factory::pair_exists(token, intermediate) && amm_factory::pair_exists(intermediate, anchor_token)) {
              
              let pair1 = amm_pair::liquidity_pool(token, intermediate);
              let (reserve1_0, reserve1_1, _) = amm_pair::get_reserves(pair1);
              let (_, intermediate_token_in_pair1) = sort::sort_two_tokens(token, intermediate);
              let liquidity1 = if (object::object_address(&intermediate_token_in_pair1) == object::object_address(&intermediate)) {
                  get_quantity(intermediate, reserve1_1)
              } else {
                  get_quantity(intermediate, reserve1_0)
              };

              let pair2 = amm_pair::liquidity_pool(intermediate, anchor_token);
              let (reserve2_0, reserve2_1, _) = amm_pair::get_reserves(pair2);
              let (_, anchor_token_in_pair2) = sort::sort_two_tokens(intermediate, anchor_token);
              let liquidity2 = if (object::object_address(&anchor_token_in_pair2) == object::object_address(&anchor_token)) {
                  get_quantity(anchor_token, reserve2_1)
              } else {
                  get_quantity(anchor_token, reserve2_0)
              };

              let current_path_liquidity = if (liquidity1 < liquidity2) { liquidity1 } else { liquidity2 };

              if (current_path_liquidity > highest_path_liquidity) {
                  highest_path_liquidity = current_path_liquidity;
                  let inter_price = consult(token, amount, intermediate);

                  best_price = (consult(intermediate, inter_price, anchor_token) as u128);
              }
          };
          i = i + 1;
      };

      (best_price as u128)
  }

  #[view]
  public fun get_average_price_v2(token: Object<Metadata>): u128 acquires Oracle {
      let signer_address = amm_controller::get_signer_address();
      let anchor_token = borrow_global<Oracle>(signer_address).anchor_token;
      
      let raw_price_q64 = consult_v2(token, anchor_token);

      if (raw_price_q64 == 0) {
          return 0
      };

      let token_decimals = fungible_asset::decimals(token);
      let decimal_factor = math64::pow(10, (token_decimals as u64));

      if (decimal_factor > 0) {
          assert!(
              raw_price_q64 <= (MAX_U128 / (decimal_factor as u128)), 
              error::invalid_argument(ERROR_PRICE_CALCULATION_OVERFLOW)
          );
      };

      raw_price_q64 * (decimal_factor as u128)
  }

  #[view]
  public fun get_current_price(token: Object<Metadata>): u128 acquires Oracle {
      let signer_address = amm_controller::get_signer_address();
      let oracle = borrow_global<Oracle>(signer_address);
      let anchor_token = oracle.anchor_token;
      let token_decimal = fungible_asset::decimals(token);

      if (token == anchor_token) {
          let anchor_token_decimal = fungible_asset::decimals(anchor_token);
          return ((math64::pow(10, (anchor_token_decimal as u64))) as u128)
      };

      if (amm_factory::pair_exists(token, anchor_token)) {
          let pair = amm_pair::liquidity_pool(token, anchor_token);
          let (reserve0, reserve1, _) = amm_pair::get_reserves(pair);
          
          let (sorted_token0, _) = razor_libs::sort::sort_two_tokens(token, anchor_token);

          if (object::object_address(&token) == object::object_address(&sorted_token0)) {
              return ((math64::pow(10, (token_decimal as u64)) as u128) * (reserve1 as u128) / (reserve0 as u128))

          } else {
              return ((math64::pow(10, (token_decimal as u64)) as u128) * (reserve0 as u128) / (reserve1 as u128))
          }
      };
     
      let best_price: u128 = 0;
      let highest_path_liquidity: u128 = 0;

      let length = get_router_token_length();
      let i = 0;
      while (i < length) {
          let intermediate = get_router_token(i);
          if (amm_factory::pair_exists(token, intermediate) && amm_factory::pair_exists(intermediate, anchor_token)) {
              
              let pair2_for_liquidity = amm_pair::liquidity_pool(intermediate, anchor_token);
              let (p2_res0, p2_res1, _) = amm_pair::get_reserves(pair2_for_liquidity);
              let (p2_sorted_token0, _) = razor_libs::sort::sort_two_tokens(intermediate, anchor_token);
              let path_liquidity = if (object::object_address(&anchor_token) == object::object_address(&p2_sorted_token0)) {
                  (p2_res0 as u128)
              } else {
                  (p2_res1 as u128) 
              };

              if (path_liquidity > highest_path_liquidity) {
                  highest_path_liquidity = path_liquidity;
                  
                  let pair1 = amm_pair::liquidity_pool(token, intermediate);
                  let (p1_res0, p1_res1, _) = amm_pair::get_reserves(pair1);
                  let (p1_sorted_token0, _) = razor_libs::sort::sort_two_tokens(token, intermediate);
                  let amount_out_intermediate = if (object::object_address(&token) == object::object_address(&p1_sorted_token0)) {
                      ((math64::pow(10, (token_decimal as u64))) as u128) * (p1_res1 as u128) / (p1_res0 as u128)
                  } else {
                      ((math64::pow(10, (token_decimal as u64))) as u128) * (p1_res0 as u128) / (p1_res1 as u128)
                  };

                  let final_amount = if (object::object_address(&intermediate) == object::object_address(&p2_sorted_token0)) {
                      (amount_out_intermediate as u128) * (p2_res1 as u128) / (p2_res0 as u128)
                  } else {
                      (amount_out_intermediate as u128) * (p2_res0 as u128) / (p2_res1 as u128)
                  };
                  best_price = final_amount;
              };
          };
          i = i + 1;
      };

      (best_price as u128)
  }
  
  // @deprecated DEPRECATED. Susceptible to overflow and loss of precision.
  // The total value of the liquidity pool may exceed the `u64` limit, leading to incorrect valuations or transaction failures.
  //
  // For accurate and safe LP token valuation, please use `get_lp_token_value_v2`, which returns a `u128`.

  #[view]
  public fun get_lp_token_value(lp_token: Object<Pair>, amount: u64): u64 acquires Oracle {
    let total_supply = amm_pair::lp_token_supply(lp_token);

    let (token0, token1) = amm_pair::unpack_pair(lp_token);
    let token0_decimal = fungible_asset::decimals(token0);
    let token1_decimal = fungible_asset::decimals(token1);
    let (reserve0, reserve1, _) = amm_pair::get_reserves(lp_token);

    let token0_value = get_average_price(token0) * (reserve0 as u128) / ((math64::pow(10, (token0_decimal as u64))) as u128);
    let token1_value = get_average_price(token1) * (reserve1 as u128) / ((math64::pow(10, (token1_decimal as u64))) as u128);

    let value = (token0_value + token1_value) * (amount as u128) / total_supply;
    (value as u64) 
  }

  #[view]
  public fun get_lp_token_value_v2(lp_token: Object<Pair>, amount: u64): u128 acquires Oracle {
    let total_supply = amm_pair::lp_token_supply(lp_token);

    let (token0, token1) = amm_pair::unpack_pair(lp_token);
    let token0_decimal = fungible_asset::decimals(token0);
    let token1_decimal = fungible_asset::decimals(token1);
    let (reserve0, reserve1, _) = amm_pair::get_reserves(lp_token);

    let token0_value = get_average_price_v2(token0) * (reserve0 as u128) / ((math64::pow(10, (token0_decimal as u64))) as u128);
    let token1_value = get_average_price_v2(token1) * (reserve1 as u128) / ((math64::pow(10, (token1_decimal as u64))) as u128);

    let value = (token0_value + token1_value) * (amount as u128) / total_supply;
    value
  }

  #[view]
  public fun get_anchor_token(): Object<Metadata> acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    borrow_global<Oracle>(signer_address).anchor_token
  }

  #[view]
  public fun get_average_block_time(): u64 acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let block_info = &borrow_global<Oracle>(signer_address).block_info;
    let height_diff = block::get_current_block_height() - block_info.height;
    assert!(height_diff > 0, error::invalid_state(ERROR_HEIGHT_DIFF_ZERO));
    let time_diff = timestamp::now_seconds() - block_info.timestamp;
    ((time_diff / height_diff) as u64)
  }

  public entry fun add_router_token(sender: &signer, token: Object<Metadata>) acquires Oracle {
    assert!(signer::address_of(sender) == amm_controller::get_admin(), error::permission_denied(ERROR_ONLY_ADMIN));
    let signer_address = amm_controller::get_signer_address();
    let oracle = borrow_global_mut<Oracle>(signer_address);
    let tokens = &mut oracle.router_tokens;

    assert!(smart_vector::length(tokens) < MAX_ROUTER_TOKENS, error::invalid_argument(ERROR_ROUTER_LIST_FULL));

    smart_vector::push_back(tokens, token);

    event::emit(RouterTokenEvent {
      token: object::object_address(&token),
      is_added: true,
    });
  }

  public entry fun remove_router_token(sender: &signer, token: Object<Metadata>) acquires Oracle {
    assert!(signer::address_of(sender) == amm_controller::get_admin(), error::permission_denied(ERROR_ONLY_ADMIN));
    let signer_address = amm_controller::get_signer_address();
    let oracle = borrow_global_mut<Oracle>(signer_address);
    let tokens = &mut oracle.router_tokens;
    let (found, index) = smart_vector::index_of(tokens, &token);
    assert!(found, error::invalid_argument(ERROR_TOKEN_NOT_FOUND));
    smart_vector::remove(tokens, index);

    event::emit(RouterTokenEvent {
      token: object::object_address(&token),
      is_added: false,
    });
  }

  #[view]
  public fun get_router_token_length(): u64 acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let tokens = &borrow_global<Oracle>(signer_address).router_tokens;
    smart_vector::length(tokens)
  }

  #[view]
  public fun is_router_token(token: Object<Metadata>): bool acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let tokens = &borrow_global<Oracle>(signer_address).router_tokens;
    let contains = smart_vector::contains(tokens, &token);
    contains
  }

  #[view]
  public fun get_router_token(index: u64): Object<Metadata> acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let tokens = &borrow_global<Oracle>(signer_address).router_tokens;
    let length = smart_vector::length(tokens);
    assert!(index < length, error::invalid_argument(ERROR_INDEX_OUT_OF_BOUNDS));
    *smart_vector::borrow(tokens, index)
  }

  #[view]
  public fun get_router_token_address(index: u64): address acquires Oracle {
    let signer_address = amm_controller::get_signer_address();
    let tokens = &borrow_global<Oracle>(signer_address).router_tokens;
    let length = smart_vector::length(tokens);
    assert!(index < length, error::invalid_argument(ERROR_INDEX_OUT_OF_BOUNDS));
    let token = *smart_vector::borrow(tokens, index);
    return object::object_address(&token)
  }
}
