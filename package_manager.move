module spike_amm::package_manager {
    use supra_framework::account::{Self, SignerCapability};
    use aptos_std::smart_table::{Self, SmartTable};
    use std::string::String;

    friend spike_amm::coin_wrapper;
    friend spike_amm::amm_router;
    friend spike_amm::router_stake;

    struct PermissionConfig has key {
        signer_cap: SignerCapability,
        addresses: SmartTable<String, address>,
    }

    fun init_module(swap_signer: &signer) {
        let (_, signer_cap) = account::create_resource_account(swap_signer, b"spike_amm_seed");
        
        move_to(swap_signer, PermissionConfig {
            addresses: smart_table::new<String, address>(),
            signer_cap,
        });
    }

    public(friend) fun get_signer(): signer acquires PermissionConfig {
        let signer_cap = &borrow_global<PermissionConfig>(@spike_amm).signer_cap;
        account::create_signer_with_capability(signer_cap)
    }

    public(friend) fun add_address(name: String, object: address) acquires PermissionConfig {
        let addresses = &mut borrow_global_mut<PermissionConfig>(@spike_amm).addresses;
        smart_table::add(addresses, name, object);
    }

    public fun address_exists(name: String): bool acquires PermissionConfig {
        smart_table::contains(&safe_permission_config().addresses, name)
    }

    public fun get_address(name: String): address acquires PermissionConfig {
        let addresses = &borrow_global<PermissionConfig>(@spike_amm).addresses;
        *smart_table::borrow(addresses, name)
    }

    inline fun safe_permission_config(): &PermissionConfig acquires PermissionConfig {
        borrow_global<PermissionConfig>(@spike_amm)
    }
}