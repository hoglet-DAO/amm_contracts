module spike_amm::oracle_library {
  use supra_framework::object::Object;
  use supra_framework::timestamp;

  use spike_amm::amm_pair::{Self, Pair};
  
  use razor_libs::math;
  use razor_libs::fixedpoint64;

  #[view]
  public fun current_block_timestamp(): u64 {
    timestamp::now_seconds()
  }

  #[view]
  public fun current_cumulative_prices(pair: Object<Pair>): (u128, u128, u64) {
    let block_timestamp = current_block_timestamp();
    let (price0, price1) = amm_pair::get_cumulative_prices(pair);

    let (reserve0, reserve1, block_timestamp_last) = amm_pair::get_reserves(pair);
    if (block_timestamp_last != block_timestamp) {
      let time_elapsed = ((block_timestamp - block_timestamp_last) as u128);
      let price0_delta = fixedpoint64::to_u128(fixedpoint64::fraction(reserve1, reserve0)) * time_elapsed;
      let price1_delta = fixedpoint64::to_u128(fixedpoint64::fraction(reserve0, reserve1)) * time_elapsed;
      price0 = math::overflow_add(price0, price0_delta);
      price1 = math::overflow_add(price1, price1_delta);
    };

    (price0, price1, block_timestamp)
  }
}