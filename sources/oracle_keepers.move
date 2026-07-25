module spike_amm::oracle_keepers {
    use spike_amm::amm_oracle::{Self, Oracle};
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Metadata};
    use std::signer;

    public entry fun call_update_by_address(
        _sender: &signer,
        tokenA_address: address,
        tokenB_address: address
    ) {
        let tokenA: Object<Metadata> = object::address_to_object<Metadata>(tokenA_address);
        let tokenB: Object<Metadata> = object::address_to_object<Metadata>(tokenB_address);
        amm_oracle::update(tokenA, tokenB);
    }

    public entry fun call_update_block_info(
        _sender: &signer
    ) {
        amm_oracle::update_block_info();
    }
}
