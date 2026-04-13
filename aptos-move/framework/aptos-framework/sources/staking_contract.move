/// Allow stakers and operators to enter a staking contract with reward sharing.
///
/// In the redesigned flow, `staking_registry` is the single economic ledger:
/// 1. Principal is deposited into the registry and delegated to the staking contract pool.
/// 2. Rewards and transaction fees accumulate as pending income in the registry.
/// 3. `staking_contract` only schedules distributions and controls validator metadata on the underlying stake pool.
/// 4. Once principal or income is claimed into the contract account, `distribute()` fans coins out to recipients.
module aptos_framework::staking_contract {
    use std::bcs;
    use std::error;
    use std::features;
    use std::signer;
    #[test_only]
    use aptos_std::bls12381;
    use aptos_std::pool_u64::{Self, Pool};
    use aptos_std::simple_map::{Self, SimpleMap};

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::topo_account;
    use aptos_framework::topo_coin::TopoCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::emit;
    #[test_only]
    use aptos_framework::poc_power_store;
    use aptos_framework::stake::{Self, OwnerCapability};
    use aptos_framework::staking_registry;
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::topo_coin;
    const SALT: vector<u8> = b"aptos_framework::staking_contract";

    /// Store amount must be at least the min stake required for a stake pool to join the validator set.
    const EINSUFFICIENT_STAKE_AMOUNT: u64 = 1;
    /// Commission percentage has to be between 0 and 100.
    const EINVALID_COMMISSION_PERCENTAGE: u64 = 2;
    /// Staker has no staking contracts.
    const ENO_STAKING_CONTRACT_FOUND_FOR_STAKER: u64 = 3;
    /// No staking contract between the staker and operator found.
    const ENO_STAKING_CONTRACT_FOUND_FOR_OPERATOR: u64 = 4;
    /// Staking contracts can't be merged.
    const ECANT_MERGE_STAKING_CONTRACTS: u64 = 5;
    /// The staking contract already exists and cannot be re-created.
    const ESTAKING_CONTRACT_ALREADY_EXISTS: u64 = 6;
    /// Not enough active stake to withdraw. Some stake might still pending and will be active in the next epoch.
    const EINSUFFICIENT_ACTIVE_STAKE_TO_WITHDRAW: u64 = 7;
    /// Caller must be either the staker, operator, or beneficiary.
    const ENOT_STAKER_OR_OPERATOR_OR_BENEFICIARY: u64 = 8;
    /// Changing beneficiaries for operators is not supported.
    const EOPERATOR_BENEFICIARY_CHANGE_NOT_SUPPORTED: u64 = 9;

    /// Maximum number of distributions a stake pool can support.
    const MAXIMUM_PENDING_DISTRIBUTIONS: u64 = 20;

    struct StakingContract has store {
        // Recorded principal after the last commission distribution.
        // This is only used to calculate the commission the operator should be receiving.
        principal: u64,
        pool_address: address,
        // The stake pool's owner capability. This can be used to control funds in the stake pool.
        owner_cap: OwnerCapability,
        commission_percentage: u64,
        // Current distributions, including operator commission withdrawals and staker's partial withdrawals.
        distribution_pool: Pool,
        // Just in case we need the SignerCap for stake pool account in the future.
        signer_cap: SignerCapability
    }

    struct Staker has key, copy, drop, store {
        staker: address
    }

    struct Store has key {
        staking_contracts: SimpleMap<address, StakingContract>
    }

    struct BeneficiaryForOperator has key {
        beneficiary_for_operator: address
    }

    #[event]
    struct UpdateCommission has drop, store {
        staker: address,
        operator: address,
        old_commission_percentage: u64,
        new_commission_percentage: u64
    }

    #[event]
    struct CreateStakingContract has drop, store {
        operator: address,
        pool_address: address,
        principal: u64,
        commission_percentage: u64
    }

    #[event]
    struct ResetLockup has drop, store {
        operator: address,
        pool_address: address
    }

    #[event]
    struct AddStake has drop, store {
        operator: address,
        pool_address: address,
        amount: u64
    }

    #[event]
    struct RequestCommission has drop, store {
        operator: address,
        pool_address: address,
        accumulated_rewards: u64,
        commission_amount: u64
    }

    #[event]
    struct UnlockStake has drop, store {
        operator: address,
        pool_address: address,
        amount: u64,
        commission_paid: u64
    }

    #[event]
    struct SwitchOperator has drop, store {
        old_operator: address,
        new_operator: address,
        pool_address: address
    }

    #[event]
    struct AddDistribution has drop, store {
        operator: address,
        pool_address: address,
        amount: u64
    }

    #[event]
    struct Distribute has drop, store {
        operator: address,
        pool_address: address,
        recipient: address,
        amount: u64
    }

    #[event]
    struct SetBeneficiaryForOperator has drop, store {
        operator: address,
        old_beneficiary: address,
        new_beneficiary: address
    }

    #[view]
    /// Return the address of the underlying stake pool for the staking contract between the provided staker and
    /// operator.
    ///
    /// This errors out the staking contract with the provided staker and operator doesn't exist.
    public fun stake_pool_address(staker: address, operator: address): address acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        staking_contracts.borrow(&operator).pool_address
    }

    #[view]
    /// Return the staker address for the provided pool address.
    ///
    /// If the pool address doesn't exist,
    /// or it's not a stake pool account,
    /// or the pool is created by a staker other than this module,
    /// or the pool is created before this feature,
    /// return None.
    public fun staker_address(pool_address: address): std::option::Option<address> acquires Staker {
        if (exists<Staker>(pool_address)) {
            return std::option::some(borrow_global<Staker>(pool_address).staker)
        } else {
            std::option::none()
        }
    }

    #[view]
    /// Return the last recorded principal (the amount that 100% belongs to the staker with commission already paid for)
    /// for staking contract between the provided staker and operator.
    ///
    /// This errors out the staking contract with the provided staker and operator doesn't exist.
    public fun last_recorded_principal(
        staker: address, operator: address
    ): u64 acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        staking_contracts.borrow(&operator).principal
    }

    #[view]
    /// Return percentage of accumulated rewards that will be paid to the operator as commission for staking contract
    /// between the provided staker and operator.
    ///
    /// This errors out the staking contract with the provided staker and operator doesn't exist.
    public fun commission_percentage(staker: address, operator: address): u64 acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        staking_contracts.borrow(&operator).commission_percentage
    }

    #[view]
    /// Return a tuple of three numbers:
    /// 1. The total active stake in the underlying stake pool
    /// 2. The total accumulated rewards that haven't had commission paid out
    /// 3. The commission amount owned from those accumulated rewards.
    ///
    /// This errors out the staking contract with the provided staker and operator doesn't exist.
    public fun staking_contract_amounts(
        staker: address, operator: address
    ): (u64, u64, u64) acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        let staking_contract = staking_contracts.borrow(&operator);
        get_staking_contract_amounts_internal(staker, staking_contract)
    }

    #[view]
    /// Return the number of pending distributions (e.g. commission, withdrawals from stakers).
    ///
    /// This errors out the staking contract with the provided staker and operator doesn't exist.
    public fun pending_distribution_counts(
        staker: address, operator: address
    ): u64 acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        staking_contracts.borrow(&operator).distribution_pool.shareholders_count()
    }

    #[view]
    /// Return true if the staking contract between the provided staker and operator exists.
    public fun staking_contract_exists(
        staker: address, operator: address
    ): bool acquires Store {
        if (!exists<Store>(staker)) {
            return false
        };

        let store = borrow_global<Store>(staker);
        store.staking_contracts.contains_key(&operator)
    }

    #[view]
    /// Return the beneficiary address of the operator.
    public fun beneficiary_for_operator(operator: address): address acquires BeneficiaryForOperator {
        if (exists<BeneficiaryForOperator>(operator)) {
            return borrow_global<BeneficiaryForOperator>(operator).beneficiary_for_operator
        } else {
            operator
        }
    }

    #[view]
    /// Return the address of the stake pool to be created with the provided staker, operator and seed.
    public fun get_expected_stake_pool_address(
        staker: address, operator: address, contract_creation_seed: vector<u8>
    ): address {
        let seed = create_resource_account_seed(staker, operator, contract_creation_seed);
        account::create_resource_address(&staker, seed)
    }

    #[view]
    /// Returns the current pending amount attributable to a specific account
    /// as recorded in the staking contract's distribution_pool.
    ///
    /// IMPORTANT SEMANTICS:
    /// - This function returns a SNAPSHOT of the staking contract's attribution ledger.
    ///   It reflects amounts that have been unlocked and recorded via the contract,
    ///   but NOT necessarily the stake pool's latest withdrawable balances.
    /// - The returned value does NOT automatically reflect newly unlocked stake or commission
    ///   unless the contract state has been advanced (e.g. via unlock or distribute paths).
    /// - Operator commission is recorded under the operator address in the distribution_pool,
    ///   but may ultimately be paid to a separate beneficiary address during distribution.
    ///   Call `beneficiary_for_operator(operator)` to determine the final recipient.
    ///
    /// USAGE NOTES:
    /// - To query the staker's pending amount, pass `account = staker`.
    /// - To query the operator's pending commission, pass `account = operator`.
    /// - In operator-switch scenarios, the previous operator may still have a
    ///   non-zero pending attribution; in that case, pass `account = old_operator`.
    ///
    /// This function MUST NOT be interpreted as a real-time or pool-level balance.
    public fun pending_attribution_snapshot(
        staker: address, operator: address, account: address
    ): u64 acquires Store {
        assert_staking_contract_exists(staker, operator);
        let staking_contracts = &Store[staker].staking_contracts;
        let staking_contract = staking_contracts.borrow(&operator);

        staking_contract.distribution_pool.balance(account)
    }

    /// Staker can call this function to create a simple staking contract with a specified operator.
    public entry fun create_staking_contract(
        staker: &signer,
        operator: address,
        amount: u64,
        commission_percentage: u64,
        // Optional seed used when creating the staking contract account.
        contract_creation_seed: vector<u8>
    ) acquires Store {
        let staked_coins = coin::withdraw<TopoCoin>(staker, amount);
        create_staking_contract_with_coins(
            staker,
            operator,
            staked_coins,
            commission_percentage,
            contract_creation_seed
        );
    }

    /// Staker can call this function to create a simple staking contract with a specified operator.
    public fun create_staking_contract_with_coins(
        staker: &signer,
        operator: address,
        coins: Coin<TopoCoin>,
        commission_percentage: u64,
        // Optional seed used when creating the staking contract account.
        contract_creation_seed: vector<u8>
    ): address acquires Store {
        assert!(
            commission_percentage >= 0 && commission_percentage <= 100,
            error::invalid_argument(EINVALID_COMMISSION_PERCENTAGE)
        );
        let principal = coin::value(&coins);
        assert!(principal > 0, error::invalid_argument(EINSUFFICIENT_STAKE_AMOUNT));

        // Initialize Store resource if this is the first time the staker has delegated to anyone.
        let staker_address = signer::address_of(staker);
        if (!exists<Store>(staker_address)) {
            move_to(staker, new_staking_contracts_holder(staker));
        };

        // Cannot create the staking contract if it already exists.
        let store = borrow_global_mut<Store>(staker_address);
        let staking_contracts = &mut store.staking_contracts;
        assert!(
            !staking_contracts.contains_key(&operator),
            error::already_exists(ESTAKING_CONTRACT_ALREADY_EXISTS)
        );

        // Initialize the stake pool in a new resource account. This allows the same staker to contract with multiple
        // different operators.
        let (stake_pool_signer, stake_pool_signer_cap, owner_cap) =
            create_stake_pool(
                staker,
                operator,
                commission_percentage,
                contract_creation_seed
            );

        let pool_address = signer::address_of(&stake_pool_signer);
        staking_registry::deposit_coins(staker_address, coins);
        staking_registry::delegate_for(staker_address, pool_address);

        // Create the staker record.
        move_to(&stake_pool_signer, Staker { staker: staker_address });

        // Create the contract record.
        staking_contracts.add(
            operator,
            StakingContract {
                principal,
                pool_address,
                owner_cap,
                commission_percentage,
                // Make sure we don't have too many pending recipients in the distribution pool.
                // Otherwise, a griefing attack is possible where the staker can keep switching operators and create too
                // many pending distributions. This can lead to out-of-gas failure whenever distribute() is called.
                distribution_pool: pool_u64::create(MAXIMUM_PENDING_DISTRIBUTIONS),
                signer_cap: stake_pool_signer_cap
            }
        );

        emit(
            CreateStakingContract {
                operator,
                pool_address,
                principal,
                commission_percentage
            }
        );
        pool_address
    }

    /// Add more stake to an existing staking contract.
    public entry fun add_stake(
        staker: &signer, operator: address, amount: u64
    ) acquires Store {
        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, operator);

        let store = borrow_global_mut<Store>(staker_address);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);

        let staked_coins = coin::withdraw<TopoCoin>(staker, amount);
        staking_registry::deposit_coins(staker_address, staked_coins);

        staking_contract.principal += amount;
        let pool_address = staking_contract.pool_address;
        emit(AddStake { operator, pool_address, amount });
    }

    /// Convenient function to allow the staker to reset their stake pool's lockup period to start now.
    public entry fun reset_lockup(staker: &signer, operator: address) acquires Store {
        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, operator);

        let store = borrow_global_mut<Store>(staker_address);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);
        let pool_address = staking_contract.pool_address;
        stake::increase_lockup_with_cap(&staking_contract.owner_cap);

        emit(ResetLockup { operator, pool_address });
    }

    /// Convenience function to allow a staker to update the commission percentage paid to the operator.
    /// TODO: fix the typo in function name. commision -> commission
    public entry fun update_commision(
        staker: &signer, operator: address, new_commission_percentage: u64
    ) acquires Store, BeneficiaryForOperator {
        assert!(
            new_commission_percentage >= 0 && new_commission_percentage <= 100,
            error::invalid_argument(EINVALID_COMMISSION_PERCENTAGE)
        );

        let staker_address = signer::address_of(staker);
        assert!(
            exists<Store>(staker_address),
            error::not_found(ENO_STAKING_CONTRACT_FOUND_FOR_STAKER)
        );

        let store = borrow_global_mut<Store>(staker_address);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);
        distribute_internal(
            staker_address,
            operator,
            staking_contract,
        );
        request_commission_internal(
            staker_address,
            operator,
            staking_contract,
        );
        let old_commission_percentage = staking_contract.commission_percentage;
        staking_contract.commission_percentage = new_commission_percentage;
        emit(
            UpdateCommission {
                staker: staker_address,
                operator,
                old_commission_percentage,
                new_commission_percentage
            }
        );
    }

    /// Unlock commission amount from the stake pool. Operator needs to wait for the amount to become withdrawable
    /// at the end of the stake pool's lockup period before they can actually can withdraw_commission.
    ///
    /// Only staker, operator or beneficiary can call this.
    public entry fun request_commission(
        account: &signer, staker: address, operator: address
    ) acquires Store, BeneficiaryForOperator {
        let account_addr = signer::address_of(account);
        assert!(
            account_addr == staker
                || account_addr == operator
                || account_addr == beneficiary_for_operator(operator),
            error::unauthenticated(ENOT_STAKER_OR_OPERATOR_OR_BENEFICIARY)
        );
        assert_staking_contract_exists(staker, operator);

        let store = borrow_global_mut<Store>(staker);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);
        // Short-circuit if zero commission.
        if (staking_contract.commission_percentage == 0) { return };

        // Force distribution of any already inactive stake.
        distribute_internal(
            staker,
            operator,
            staking_contract,
        );

        request_commission_internal(
            staker,
            operator,
            staking_contract,
        );
    }

    fun request_commission_internal(
        staker: address,
        operator: address,
        staking_contract: &mut StakingContract,
    ): u64 {
        claim_and_schedule_pending_income(staker, operator, staking_contract)
    }

    /// Staker can call this to request withdrawal of part or all of their staking_contract.
    /// This also triggers paying commission to the operator for accounting simplicity.
    public entry fun unlock_stake(
        staker: &signer, operator: address, amount: u64
    ) acquires Store, BeneficiaryForOperator {
        // Short-circuit if amount is 0.
        if (amount == 0) return;

        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, operator);

        let store = borrow_global_mut<Store>(staker_address);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);

        // Force distribution of any already inactive stake.
        distribute_internal(
            staker_address,
            operator,
            staking_contract,
        );

        // For simplicity, we request commission to be paid out first. This avoids having to ensure to staker doesn't
        // withdraw into the commission portion.
        let commission_paid =
            request_commission_internal(
                staker_address,
                operator,
                staking_contract,
            );

        let (deposit, _, _) = staking_registry::get_user_stake_info(staker_address);
        if (staking_contract.principal < amount) {
            amount = staking_contract.principal;
        };
        if (deposit < amount) {
            amount = deposit;
        };
        if (amount == 0) {
            return
        };
        staking_contract.principal -= amount;
        let coins = staking_registry::extract_deposit_as_coins(staker_address, amount);
        topo_account::deposit_coins(staking_contract.pool_address, coins);
        add_distribution(
            operator,
            staking_contract,
            staker_address,
            amount,
        );

        let pool_address = staking_contract.pool_address;
        emit(
            UnlockStake { pool_address, operator, amount, commission_paid }
        );
    }

    /// Unlock all accumulated rewards since the last recorded principals.
    public entry fun unlock_rewards(
        staker: &signer, operator: address
    ) acquires Store, BeneficiaryForOperator {
        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, operator);

        let store = borrow_global_mut<Store>(staker_address);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);
        distribute_internal(
            staker_address,
            operator,
            staking_contract,
        );
        claim_and_schedule_pending_income(
            staker_address,
            operator,
            staking_contract,
        );
    }

    /// Allows staker to switch operator without going through the lenghthy process to unstake, without resetting commission.
    public entry fun switch_operator_with_same_commission(
        staker: &signer, old_operator: address, new_operator: address
    ) acquires Store, BeneficiaryForOperator {
        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, old_operator);

        let commission_percentage = commission_percentage(staker_address, old_operator);
        switch_operator(
            staker,
            old_operator,
            new_operator,
            commission_percentage
        );
    }

    /// Allows staker to switch operator without going through the lenghthy process to unstake.
    public entry fun switch_operator(
        staker: &signer,
        old_operator: address,
        new_operator: address,
        new_commission_percentage: u64
    ) acquires Store, BeneficiaryForOperator {
        let staker_address = signer::address_of(staker);
        assert_staking_contract_exists(staker_address, old_operator);

        assert!(
            new_commission_percentage <= 100,
            error::invalid_argument(EINVALID_COMMISSION_PERCENTAGE)
        );
        // Merging two existing staking contracts is too complex as we'd need to merge two separate stake pools.
        let store = borrow_global_mut<Store>(staker_address);
        let staking_contracts = &mut store.staking_contracts;
        assert!(
            !staking_contracts.contains_key(&new_operator),
            error::invalid_state(ECANT_MERGE_STAKING_CONTRACTS)
        );

        let (_, staking_contract) = staking_contracts.remove(&old_operator);
        // Force distribution of any already inactive stake.
        distribute_internal(
            staker_address,
            old_operator,
            &mut staking_contract,
        );

        // For simplicity, we request commission to be paid out first. This avoids having to ensure to staker doesn't
        // withdraw into the commission portion.
        request_commission_internal(
            staker_address,
            old_operator,
            &mut staking_contract,
        );

        // Update the staking contract's commission rate and stake pool's operator.
        stake::set_operator_with_cap(&staking_contract.owner_cap, new_operator);
        staking_contract.commission_percentage = new_commission_percentage;

        let pool_address = staking_contract.pool_address;
        staking_contracts.add(new_operator, staking_contract);
        emit(SwitchOperator { pool_address, old_operator, new_operator });
    }

    /// Allows an operator to change its beneficiary. Any existing unpaid commission rewards will be paid to the new
    /// beneficiary. To ensures payment to the current beneficiary, one should first call `distribute` before switching
    /// the beneficiary. An operator can set one beneficiary for staking contract pools, not a separate one for each pool.
    public entry fun set_beneficiary_for_operator(
        operator: &signer, new_beneficiary: address
    ) acquires BeneficiaryForOperator {
        assert!(
            features::operator_beneficiary_change_enabled(),
            std::error::invalid_state(EOPERATOR_BENEFICIARY_CHANGE_NOT_SUPPORTED)
        );
        // The beneficiay address of an operator is stored under the operator's address.
        // So, the operator does not need to be validated with respect to a staking pool.
        let operator_addr = signer::address_of(operator);
        let old_beneficiary = beneficiary_for_operator(operator_addr);
        if (exists<BeneficiaryForOperator>(operator_addr)) {
            borrow_global_mut<BeneficiaryForOperator>(operator_addr).beneficiary_for_operator =
                new_beneficiary;
        } else {
            move_to(
                operator,
                BeneficiaryForOperator { beneficiary_for_operator: new_beneficiary }
            );
        };

        emit(
            SetBeneficiaryForOperator {
                operator: operator_addr,
                old_beneficiary,
                new_beneficiary
            }
        );
    }

    /// Allow anyone to distribute already unlocked funds. This does not affect reward compounding and therefore does
    /// not need to be restricted to just the staker or operator.
    public entry fun distribute(
        staker: address, operator: address
    ) acquires Store, BeneficiaryForOperator {
        assert_staking_contract_exists(staker, operator);
        let store = borrow_global_mut<Store>(staker);
        let staking_contract = store.staking_contracts.borrow_mut(&operator);
        distribute_internal(
            staker,
            operator,
            staking_contract,
        );
    }

    /// Distribute all unlocked (inactive) funds according to distribution shares.
    fun distribute_internal(
        staker: address,
        operator: address,
        staking_contract: &mut StakingContract,
    ) acquires BeneficiaryForOperator {
        let pool_address = staking_contract.pool_address;
        // Create the Staker resource if it doesn't exist to backfill the Staker resource for each pool.
        if (!exists<Staker>(pool_address)) {
            let pool_signer =
                &account::create_signer_with_capability(&staking_contract.signer_cap);
            move_to(pool_signer, Staker { staker });
        };
        let pool_signer =
            &account::create_signer_with_capability(&staking_contract.signer_cap);
        let withdrawable = coin::balance<TopoCoin>(pool_address);
        let coins = coin::withdraw<TopoCoin>(pool_signer, withdrawable);
        let distribution_amount = coin::value(&coins);
        if (distribution_amount == 0) {
            coin::destroy_zero(coins);
            return
        };

        let distribution_pool = &mut staking_contract.distribution_pool;
        // Buy all recipients out of the distribution pool.
        while (distribution_pool.shareholders_count() > 0) {
            let recipients = distribution_pool.shareholders();
            let recipient = recipients[0];
            let current_shares = distribution_pool.shares(recipient);
            let amount_to_distribute =
                distribution_pool.redeem_shares(recipient, current_shares);
            // If the recipient is the operator, send the commission to the beneficiary instead.
            if (recipient == operator) {
                recipient = beneficiary_for_operator(operator);
            };
            topo_account::deposit_coins(
                recipient, coin::extract(&mut coins, amount_to_distribute)
            );

            emit(
                Distribute {
                    operator,
                    pool_address,
                    recipient,
                    amount: amount_to_distribute
                }
            );
        };

        // In case there's any dust left, send them all to the staker.
        if (coin::value(&coins) > 0) {
            topo_account::deposit_coins(staker, coins);
            distribution_pool.update_total_coins(0);
        } else {
            coin::destroy_zero(coins);
        }
    }

    /// Assert that a staking_contract exists for the staker/operator pair.
    fun assert_staking_contract_exists(
        staker: address, operator: address
    ) acquires Store {
        assert!(
            exists<Store>(staker),
            error::not_found(ENO_STAKING_CONTRACT_FOUND_FOR_STAKER)
        );
        let staking_contracts = &borrow_global<Store>(staker).staking_contracts;
        assert!(
            staking_contracts.contains_key(&operator),
            error::not_found(ENO_STAKING_CONTRACT_FOUND_FOR_OPERATOR)
        );
    }

    /// Add a new distribution for `recipient` and `amount` to the staking contract's distributions list.
    fun add_distribution(
        operator: address,
        staking_contract: &mut StakingContract,
        recipient: address,
        coins_amount: u64,
    ) {
        let distribution_pool = &mut staking_contract.distribution_pool;
        distribution_pool.buy_in(recipient, coins_amount);
        let pool_address = staking_contract.pool_address;
        emit(AddDistribution { operator, pool_address, amount: coins_amount });
    }

    /// Calculate accumulated rewards and commissions since last update.
    fun get_staking_contract_amounts_internal(
        staker: address,
        staking_contract: &StakingContract
    ): (u64, u64, u64) {
        let (pending_reward, pending_fee, _) =
            staking_registry::get_user_pending_income(staker);
        let accumulated_rewards = pending_reward + pending_fee;
        let commission_amount =
            accumulated_rewards * staking_contract.commission_percentage / 100;

        (
            staking_contract.principal + accumulated_rewards,
            accumulated_rewards,
            commission_amount,
        )
    }

    fun create_stake_pool(
        staker: &signer,
        operator: address,
        commission_percentage: u64,
        contract_creation_seed: vector<u8>
    ): (signer, SignerCapability, OwnerCapability) {
        // Generate a seed that will be used to create the resource account that hosts the staking contract.
        let seed =
            create_resource_account_seed(
                signer::address_of(staker), operator, contract_creation_seed
            );

        let (stake_pool_signer, stake_pool_signer_cap) =
            account::create_resource_account(staker, seed);
        coin::register<TopoCoin>(&stake_pool_signer);
        stake::initialize_stake_pool(&stake_pool_signer, operator);

        let pool_address = signer::address_of(&stake_pool_signer);
        staking_registry::register_validator_for_owner(
            signer::address_of(staker),
            pool_address,
            commission_percentage * 100,
        );

        // Extract owner_cap from the StakePool, so we have control over it in the staking_contracts flow.
        // This is stored as part of the staking_contract. Thus, the staker would not have direct control over it without
        // going through well-defined functions in this module.
        let owner_cap = stake::extract_owner_cap(&stake_pool_signer);

        (stake_pool_signer, stake_pool_signer_cap, owner_cap)
    }

    fun claim_and_schedule_pending_income(
        staker: address,
        operator: address,
        staking_contract: &mut StakingContract,
    ): u64 {
        let (pending_reward, pending_fee, locked_until_secs) =
            staking_registry::get_user_pending_income(staker);
        let total_income = pending_reward + pending_fee;
        if (total_income == 0) {
            return 0
        };
        if (locked_until_secs != 0 && timestamp::now_seconds() < locked_until_secs) {
            return 0
        };

        let claimed_coins = staking_registry::claim_pending_income_as_coins(staker);
        let claimed_amount = coin::value(&claimed_coins);
        if (claimed_amount == 0) {
            coin::destroy_zero(claimed_coins);
            return 0
        };
        topo_account::deposit_coins(staking_contract.pool_address, claimed_coins);

        let commission_amount = claimed_amount * staking_contract.commission_percentage / 100;
        let staker_amount = claimed_amount - commission_amount;
        if (staker_amount > 0) {
            add_distribution(operator, staking_contract, staker, staker_amount);
        };
        if (commission_amount > 0) {
            add_distribution(operator, staking_contract, operator, commission_amount);
        };

        emit(
            RequestCommission {
                operator,
                pool_address: staking_contract.pool_address,
                accumulated_rewards: claimed_amount,
                commission_amount,
            }
        );

        commission_amount
    }

    /// Create the seed to derive the resource account address.
    fun create_resource_account_seed(
        staker: address, operator: address, contract_creation_seed: vector<u8>
    ): vector<u8> {
        let seed = bcs::to_bytes(&staker);
        seed.append(bcs::to_bytes(&operator));
        // Include a salt to avoid conflicts with any other modules out there that might also generate
        // deterministic resource accounts for the same staker + operator addresses.
        seed.append(SALT);
        // Add an extra salt given by the staker in case an account with the same address has already been created.
        seed.append(contract_creation_seed);
        seed
    }

    /// Create a new staking_contracts resource.
    fun new_staking_contracts_holder(_staker: &signer): Store {
        Store { staking_contracts: simple_map::create<address, StakingContract>() }
    }

    #[test(aptos_framework = @0x1, staker = @0x123, operator = @0x234)]
    public entry fun test_staking_contract_pool_can_join_validator_set(
        aptos_framework: &signer,
        staker: &signer,
        operator: &signer,
    ) acquires Store {
        let stake_amount = 100;
        let commission_percentage = 10;

        stake::initialize_for_test(aptos_framework);

        let staker_address = signer::address_of(staker);
        let operator_address = signer::address_of(operator);
        account::create_account_for_test(staker_address);
        account::create_account_for_test(operator_address);
        coin::register<TopoCoin>(staker);
        topo_coin::mint(aptos_framework, staker_address, stake_amount);

        create_staking_contract(
            staker,
            operator_address,
            stake_amount,
            commission_percentage,
            x"01",
        );
        let pool_address = stake_pool_address(staker_address, operator_address);

        assert!(staking_registry::get_validator_owner(pool_address) == staker_address, 0);
        assert!(
            staking_registry::get_validator_commission_bps(pool_address)
                == commission_percentage * 100,
            1
        );

        poc_power_store::batch_update(
            aptos_framework,
            0,
            vector[staker_address],
            vector[stake_amount],
        );
        assert!(staking_registry::get_validator_joining_power(pool_address) == stake_amount, 2);
        assert!(staking_registry::get_validator_total_power(pool_address) == stake_amount, 3);

        let (_sk, pk, pop) = stake::generate_identity();
        stake::rotate_consensus_key(
            operator,
            pool_address,
            bls12381::public_key_to_bytes(&pk),
            bls12381::proof_of_possession_to_bytes(&pop),
        );
        stake::update_network_and_fullnode_addresses(
            operator,
            pool_address,
            x"",
            x"",
        );

        stake::join_validator_set(operator, pool_address);
        assert!(stake::get_validator_state(pool_address) == 1, 4);

        stake::end_epoch();
        assert!(stake::get_validator_state(pool_address) == 2, 5);
        assert!(staking_registry::get_effective_power(staker_address) == stake_amount, 6);
    }
}
