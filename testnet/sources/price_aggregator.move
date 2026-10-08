module spike_amm::price_aggregator {
    use std::error;
    use supra_framework::object::{Self};
    use supra_framework::fungible_asset::{Metadata};
    use spike_amm::amm_oracle;
    use spike_amm::coin_wrapper::{Self};
    use supra_oracle::supra_oracle_storage;

    const E_MULTIPLICATION_OVERFLOW: u64 = 1;
    const E_COIN_TYPE_NOT_SUPPORTED: u64 = 2;
    const E_PRICE_IS_ZERO: u64 = 3;
    const E_DECIMALS_TOO_LARGE_FOR_U8: u64 = 4;

    const SUPRA_USD_PAIR_ID: u32 = 500;
    const SUPRA_AMM_DECIMALS_FACTOR: u128 = 100_000_000;
    const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    const SUPRA_WRAPPED_ADDRESS: address = @BWSUP_ADDRESS;

    #[view]
    public fun get_token_price_in_usd(token_address: address): (u128, u16) {
        if (token_address == SUPRA_WRAPPED_ADDRESS) {
            let (price_supra_in_usd_scaled, supra_usd_decimals, _, _) = supra_oracle_storage::get_price(SUPRA_USD_PAIR_ID);
            assert!(price_supra_in_usd_scaled > 0, error::invalid_argument(E_PRICE_IS_ZERO));
            
            return (price_supra_in_usd_scaled, supra_usd_decimals)
        };
        
        let from_token_obj = object::address_to_object<Metadata>(token_address);
        let anchor_token = amm_oracle::get_anchor_token();
        let price_token_q64 = amm_oracle::consult_v2(from_token_obj, anchor_token);

        if (price_token_q64 == 0) {
            return (0, 0)
        };
        
        let (price_supra_in_usd_scaled, supra_usd_decimals, _, _) = supra_oracle_storage::get_price(SUPRA_USD_PAIR_ID);
        assert!(price_supra_in_usd_scaled > 0, error::invalid_argument(E_PRICE_IS_ZERO));

        let token_decimals = supra_framework::fungible_asset::decimals(from_token_obj);
        let decimal_factor = aptos_std::math64::pow(10, (token_decimals as u64));

        let product_q64 = (price_token_q64 as u256) * (price_supra_in_usd_scaled as u256);
        let product_with_decimals_q64 = product_q64 * (decimal_factor as u256);

        let final_price_scaled = (product_with_decimals_q64 / (SUPRA_AMM_DECIMALS_FACTOR as u256)) >> 64;

        ((final_price_scaled as u128), supra_usd_decimals)
    }

    #[view]
    public fun get_coin_price_in_usd<CoinType>(): (u128, u16) {
        assert!(
            coin_wrapper::is_supported<CoinType>(), 
            error::invalid_argument(E_COIN_TYPE_NOT_SUPPORTED)
        );

        let wrapper_object = coin_wrapper::get_wrapper<CoinType>();
        let wrapper_address = object::object_address(&wrapper_object);

        get_token_price_in_usd(wrapper_address)
    }
}