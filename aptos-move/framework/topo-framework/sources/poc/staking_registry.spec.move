spec aptos_framework::staking_registry {
    spec get_effective_power(user: address): u64 {
        ensures result == spec_get_effective_power(user);
    }

    spec get_validator_total_power(validator_address: address): u64 {
        ensures result == spec_get_validator_total_power(validator_address);
    }

    spec fun spec_get_effective_power(user: address): u64;
    spec fun spec_get_validator_total_power(validator_address: address): u64;
}
