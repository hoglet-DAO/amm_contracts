module spike_amm::amm_controller {
  use std::signer;
  use std::error;
  use supra_framework::object::{Self, ExtendRef};

  friend spike_amm::amm_factory;
  friend spike_amm::amm_pair;
  friend spike_amm::amm_oracle;
  friend spike_amm::coin_wrapper;
  
  const FEE_ADMIN: address = @fee_admin;
  const ADMIN: address = @admin;

  const ERROR_PAUSED: u64 = 1;
  const ERROR_UNPAUSED: u64 = 2;
  const ERROR_FORBIDDEN: u64 = 3;
  const ERROR_NO_PENDING_ADMIN: u64 = 4;
  const ERROR_INVALID_ADDRESS: u64 = 5;
  const ERROR_PENDING_ADMIN_EXISTS: u64 = 6;
  const ERROR_FEE_TOO_HIGH: u64 = 7;

  struct SwapConfig has key {
    extend_ref: ExtendRef,
    fee_to: address,
    current_admin: address,
    pending_admin: address,
    fee_on: bool,
    paused: bool,
    swap_fee: u8
  }

  struct FlashLoanConfig has key {
    fee_bps: u64,
  }

  fun init_module(deployer: &signer) {
    let constructor_ref = object::create_object(@spike_amm);
    let extend_ref = object::generate_extend_ref(&constructor_ref);

    move_to(deployer, SwapConfig {
      extend_ref: extend_ref,
      fee_to: FEE_ADMIN,
      current_admin: ADMIN,
      pending_admin: @0x0,
      fee_on: true,
      paused: false,
      swap_fee: 25
    })
  }

  public(friend) fun get_signer(): signer acquires SwapConfig {
    let ref = &safe_swap_config().extend_ref;
    object::generate_signer_for_extending(ref)
  }

  #[view]
  public fun get_signer_address(): address acquires SwapConfig {
    signer::address_of(&get_signer())
  }

  #[view]
  public fun get_swap_fee(): u8 acquires SwapConfig {
    safe_swap_config().swap_fee
  }

  #[view]
  public fun get_fee_to(): address acquires SwapConfig {
    safe_swap_config().fee_to
  }

  #[view]
  public fun get_admin(): address acquires SwapConfig {
    safe_swap_config().current_admin
  }

  #[view]
  public fun get_fee_on(): bool acquires SwapConfig {
    safe_swap_config().fee_on
  }

  #[view]
  public fun get_flash_loan_fee_bps(): u64 acquires FlashLoanConfig, SwapConfig {
    let object_addr = get_signer_address();
    if (exists<FlashLoanConfig>(object_addr)) {
        borrow_global<FlashLoanConfig>(object_addr).fee_bps
    } else {
        5
    }
  }

  public fun assert_paused() acquires SwapConfig {
  assert!(safe_swap_config().paused == true, error::invalid_state(ERROR_UNPAUSED));
  }

  public fun assert_unpaused() acquires SwapConfig {
    assert!(safe_swap_config().paused == false, error::invalid_state(ERROR_PAUSED));
  }

  public(friend) fun set_flash_loan_fee(
    account: &signer,
    new_fee_bps: u64
  ) acquires FlashLoanConfig, SwapConfig {
      let current_admin = safe_swap_config().current_admin;
      assert!(signer::address_of(account) == current_admin, error::permission_denied(ERROR_FORBIDDEN));
      assert!(new_fee_bps <= 1000, error::invalid_argument(ERROR_FEE_TOO_HIGH));

      let contract_signer = get_signer(); 
      let contract_addr = signer::address_of(&contract_signer);

      if (exists<FlashLoanConfig>(contract_addr)) {
          let config = borrow_global_mut<FlashLoanConfig>(contract_addr);
          config.fee_bps = new_fee_bps;
      } else {
            move_to(&contract_signer, FlashLoanConfig { fee_bps: new_fee_bps });
      }
  }

  public(friend) fun pause(account: &signer) acquires SwapConfig {
    assert_unpaused();
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));

    swap_config.paused = true;
  }

  public(friend) fun unpause(account: &signer) acquires SwapConfig {
    assert_paused();
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));
    swap_config.paused = false;
  }

  
  public(friend) fun set_swap_fee(
    account: &signer,
    swap_fee: u8
  ) acquires SwapConfig {
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));
    assert!(swap_fee <= 50, error::invalid_argument(ERROR_FEE_TOO_HIGH));
    swap_config.swap_fee = swap_fee;
  }

  public(friend) fun set_fee_to(
    account: &signer,
    fee_to: address
  ) acquires SwapConfig {
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));
    swap_config.fee_to = fee_to;
  }

  public(friend) fun set_admin_address(
    account: &signer,
    admin_address: address
  ) acquires SwapConfig {
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));
    assert!(admin_address != @0x0, error::invalid_argument(ERROR_INVALID_ADDRESS));
    assert!(swap_config.pending_admin == @0x0, error::invalid_state(ERROR_PENDING_ADMIN_EXISTS));
    swap_config.pending_admin = admin_address;
  }

  public(friend) fun cancel_pending_admin(
    account: &signer
  ) acquires SwapConfig {
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    assert!(signer::address_of(account) == swap_config.current_admin, error::permission_denied(ERROR_FORBIDDEN));
    swap_config.pending_admin = @0x0;
  }

  public(friend) fun claim_admin(
    account: &signer
  ) acquires SwapConfig {
    let swap_config = borrow_global_mut<SwapConfig>(@spike_amm);
    let account_addr = signer::address_of(account);
    assert!(account_addr == swap_config.pending_admin, error::permission_denied(ERROR_FORBIDDEN));
    assert!(swap_config.pending_admin != @0x0, error::invalid_state(ERROR_NO_PENDING_ADMIN));
    swap_config.current_admin = account_addr;
    swap_config.pending_admin = @0x0;
  }

  inline fun safe_swap_config(): &SwapConfig acquires SwapConfig {
    borrow_global<SwapConfig>(@spike_amm)
  }
}