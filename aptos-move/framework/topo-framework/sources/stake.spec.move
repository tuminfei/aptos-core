spec topo_framework::stake {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: The validator set resource stores consensus information for each validator. The consensus scheme
    /// remains consistent across all validators within the set.
    /// Criticality: Low
    /// Implementation: The consensus_scheme attribute within ValidatorSet initializes with the value zero during the
    /// module's initialization and its value remains unchanged afterward.
    /// Enforcement: Formally verified by the data invariant of [high-level-req-1](ValidatorSet).
    ///
    /// No.: 2
    /// Requirement: The owner of a validator is immutable.
    /// Criticality: Low
    /// Implementation: During the initialization of a validator, the owner attribute becomes the signer's address. This
    /// assignment establishes the signer as the owner and controller of the validator entity. Subsequently, the owner
    /// attribute remains unchanged throughout the validator's lifespan, maintaining its assigned value without any
    /// modifications.
    /// Enforcement: Formally verified in the schema [high-level-req-2](ValidatorOwnerNoChange).
    ///
    /// No.: 3
    /// Requirement: The total staked value in the stake pool should remain constant, excluding operations related to
    /// adding and withdrawing.
    /// Criticality: Low
    /// Implementation: The total staked value (TopoCoin) of a stake pool is grouped by: active, inactive,
    /// pending_active, and pending_inactive. The stake value remains constant except during the execution of the
    /// add_stake_with_cap or withdraw_with_cap functions or on_new_epoch (which distributes the reward).
    /// Enforcement: Formally specified in the schema [high-level-req-3](StakedValueNoChange).
    ///
    /// No.: 4
    /// 要求：安装新 Epoch 前，先结算旧委员会的奖励，再替换权重和索引。
    /// Criticality: Low
    /// 实现：原生 on_new_epoch 结算奖励、分发费用、处理本金并延长锁仓；
    /// PoC 准备后的换届使用冻结计划和旧 Epoch 的奖励上下文。状态错误或数值越界
    /// 会回滚整笔事务；PoC 目标不合格则在冻结前返回 Deferred。
    /// 验证：原生安装与 PoC 各提交阶段的契约已经验证，
    /// 质押池所有权与奖励归属仍须结合实现审查。
    /// </high-level-req>
    ///
    // -----------------
    // Global invariants
    // -----------------
    spec module {
        pragma verify = true;
        pragma aborts_if_is_partial;
        // The validator set should satisfy its desired invariant.
        invariant [suspendable] exists<ValidatorSet>(@topo_framework) ==>
            validator_set_is_valid();
        // After genesis, `TopoCoinCapabilities`, `ValidatorPerformance` and `ValidatorSet` exist.
        invariant [suspendable] chain_status::is_operating() ==>
            exists<TopoCoinCapabilities>(@topo_framework);
        invariant [suspendable] chain_status::is_operating() ==>
            exists<ValidatorPerformance>(@topo_framework);
        invariant [suspendable] chain_status::is_operating() ==>
            exists<ValidatorSet>(@topo_framework);

        // property 2: The owner of a validator remains immutable.
        // 纯算术引理不改变链上状态，因此不应用资源变更约束。
        apply ValidatorOwnerNoChange to * except failure_count_monotonic;

        apply ValidatorNotChangeDuringReconfig to * except on_new_epoch, install_epoch_plan, failure_count_monotonic;
        apply StakePoolNotChangeDuringReconfig to * except on_new_epoch, update_stake_pool, settle_native_voters, settle_voting_pool, settle_closing_epoch, apply_stake_transitions, install_epoch_plan, failure_count_monotonic;

        // ghost variable
        global ghost_valid_perf: ValidatorPerformance;
        global ghost_proposer_idx: Option<u64>;
        global ghost_active_num: u64;
        global ghost_pending_inactive_num: u64;
    }

    // property 1: the validator set resource stores consensus information for each validator.
    // the consensus scheme remains consistent across all validators within the set.
    spec ValidatorSet {
        /// [high-level-req-1]
        invariant consensus_scheme == 0;
    }

    spec schema ValidatorNotChangeDuringReconfig {
        ensures (
            reconfiguration_state::spec_is_in_progress()
                && old(exists<ValidatorSet>(@topo_framework))
        ) ==>
            old(global<ValidatorSet>(@topo_framework))
                == global<ValidatorSet>(@topo_framework);
    }

    spec schema StakePoolNotChangeDuringReconfig {
        ensures forall a: address where old(exists<StakePool>(a)):
            reconfiguration_state::spec_is_in_progress() ==>
                (
                    old(global<StakePool>(a).pending_inactive)
                        == global<StakePool>(a).pending_inactive
                        && old(global<StakePool>(a).pending_active)
                            == global<StakePool>(a).pending_active
                        && old(global<StakePool>(a).inactive)
                            == global<StakePool>(a).inactive
                        && old(global<StakePool>(a).active)
                            == global<StakePool>(a).active
                );
    }

    spec schema ValidatorOwnerNoChange {
        /// [high-level-req-2]
        ensures forall addr: address where old(exists<OwnerCapability>(addr)):
            old(global<OwnerCapability>(addr)).pool_address
                == global<OwnerCapability>(addr).pool_address;
    }

    // property 3: The total staked value in the stake pool should be constant (excluding adding and withdrawing operations).
    spec schema StakedValueNochange {
        pool_address: address;
        let stake_pool = global<StakePool>(pool_address);
        let post post_stake_pool = global<StakePool>(pool_address);
        /// [high-level-req-3]
        ensures stake_pool.active.value + stake_pool.inactive.value
            + stake_pool.pending_active.value + stake_pool.pending_inactive.value
            == post_stake_pool.active.value + post_stake_pool.inactive.value
                + post_stake_pool.pending_active.value
                + post_stake_pool.pending_inactive.value;
    }

    // A desired invariant for the validator set.
    spec fun validator_set_is_valid(): bool {
        let validator_set = global<ValidatorSet>(@topo_framework);
        validator_set_is_valid_impl(validator_set)
    }

    spec fun validator_set_is_valid_impl(validator_set: ValidatorSet): bool {
        spec_validators_are_initialized(validator_set.active_validators)
            && spec_validators_are_initialized(validator_set.pending_inactive)
            && spec_validators_are_initialized(validator_set.pending_active)
            && spec_validator_indices_are_valid(validator_set.active_validators)
            && spec_validator_indices_are_valid(validator_set.pending_inactive)
            && spec_validator_indices_active_pending_inactive(validator_set)
    }

    // -----------------------
    // Function specifications
    // -----------------------

    spec initialize_validator(
        account: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>
    ) {
        pragma verify = false;

        let pubkey_from_pop = bls12381::spec_public_key_from_bytes_with_pop(
            consensus_pubkey,
            proof_of_possession_from_bytes(proof_of_possession)
        );
        aborts_if !option::is_some(pubkey_from_pop);
        let addr = signer::address_of(account);
        let post_addr = signer::address_of(account);
        let allowed = global<AllowedValidators>(@topo_framework);
        aborts_if exists<ValidatorConfig>(addr);
        aborts_if exists<AllowedValidators>(@topo_framework)
            && !vector::spec_contains(allowed.accounts, addr);
        aborts_if stake_pool_exists(addr);
        aborts_if exists<OwnerCapability>(addr);
        aborts_if !exists<account::Account>(addr);
        aborts_if global<account::Account>(addr).guid_creation_num + 12 > MAX_U64;
        aborts_if global<account::Account>(addr).guid_creation_num + 12
            >= account::MAX_GUID_CREATION_NUM;
        ensures exists<StakePool>(post_addr);
        ensures global<OwnerCapability>(post_addr)
            == OwnerCapability { pool_address: post_addr };
        ensures global<ValidatorConfig>(post_addr)
            == ValidatorConfig {
                consensus_pubkey,
                network_addresses,
                fullnode_addresses,
                validator_index: 0
            };
    }

    // `Validator` is initialized once.
    spec initialize(topo_framework: &signer) {
        pragma disable_invariants_in_body;
        let aptos_addr = signer::address_of(topo_framework);
        aborts_if !system_addresses::is_topo_framework_address(aptos_addr);
        aborts_if exists<ValidatorSet>(aptos_addr);
        aborts_if exists<ValidatorPerformance>(aptos_addr);
        ensures exists<ValidatorSet>(aptos_addr);
        ensures global<ValidatorSet>(aptos_addr).consensus_scheme == 0;
        ensures exists<ValidatorPerformance>(aptos_addr);
    }

    spec join_validator_set(operator: &signer, pool_address: address) {
        // This function casue timeout (property proved)
        pragma verify_duration_estimate = 60;
        pragma disable_invariants_in_body;
        aborts_if !staking_config::get_allow_validator_set_change(staking_config::get());
        aborts_if !exists<StakePool>(pool_address);
        aborts_if !exists<ValidatorConfig>(pool_address);
        aborts_if !exists<StakingConfig>(@topo_framework);
        aborts_if !exists<ValidatorSet>(@topo_framework);
        aborts_if reconfiguration_state::spec_is_in_progress();

        let stake_pool = global<StakePool>(pool_address);
        let validator_set = global<ValidatorSet>(@topo_framework);
        let post p_validator_set = global<ValidatorSet>(@topo_framework);
        aborts_if signer::address_of(operator) != stake_pool.operator_address;
        aborts_if option::is_some(
            spec_find_validator(validator_set.active_validators, pool_address)
        )
            || option::is_some(
                spec_find_validator(validator_set.pending_inactive, pool_address)
            )
            || option::is_some(
                spec_find_validator(validator_set.pending_active, pool_address)
            );

        let config = staking_config::get();
        let merge_expired_pending_inactive = stake_pool.locked_until_secs > 0
            && timestamp::spec_now_seconds() >= stake_pool.locked_until_secs;
        let effective_pending_inactive = if (merge_expired_pending_inactive) {
            0
        } else {
            stake_pool.pending_inactive.value
        };
        let voting_power = stake_pool.active.value
            + stake_pool.pending_active.value
            + effective_pending_inactive;

        let minimum_stake = config.minimum_stake;
        let maximum_stake = config.maximum_stake;
        aborts_if voting_power < minimum_stake;
        aborts_if voting_power > maximum_stake;

        let validator_config = global<ValidatorConfig>(pool_address);
        aborts_if vector::is_empty(validator_config.consensus_pubkey);

        let validator_set_size = vector::length(validator_set.active_validators)
            + vector::length(validator_set.pending_active) + 1;
        aborts_if validator_set_size > MAX_VALIDATOR_SET_SIZE;

        let voting_power_increase_limit = (
            staking_config::get_voting_power_increase_limit(config) as u128
        );

        aborts_if !spec_poc_enabled() && (validator_set.total_joining_power + (voting_power as u128)) > MAX_U128;
        aborts_if !spec_poc_enabled() && validator_set.total_voting_power * voting_power_increase_limit
            > MAX_U128;
        aborts_if !spec_poc_enabled() && validator_set.total_voting_power > 0
            && (validator_set.total_joining_power + (voting_power as u128)) * 100
                > validator_set.total_voting_power * voting_power_increase_limit;

        let post p_validator_info = ValidatorInfo {
            addr: pool_address,
            voting_power: if (spec_poc_enabled()) { 0 } else { voting_power },
            config: validator_config
        };

        ensures !spec_poc_enabled() ==> validator_set.total_joining_power + voting_power
            == p_validator_set.total_joining_power;
        ensures vector::spec_contains(p_validator_set.pending_active, p_validator_info);
    }

    spec withdraw(owner: &signer, withdraw_amount: u64) {
        // TODO(fa_migration)
        pragma verify = false;
        aborts_if reconfiguration_state::spec_is_in_progress();
        let addr = signer::address_of(owner);
        let ownership_cap = global<OwnerCapability>(addr);
        let pool_address = ownership_cap.pool_address;
        let stake_pool = global<StakePool>(pool_address);
        aborts_if !exists<OwnerCapability>(addr);
        aborts_if !exists<StakePool>(pool_address);
        aborts_if !exists<ValidatorSet>(@topo_framework);

        let validator_set = global<ValidatorSet>(@topo_framework);
        let bool_find_validator = !option::is_some(
            spec_find_validator(validator_set.active_validators, pool_address)
        )
            && !option::is_some(
                spec_find_validator(validator_set.pending_inactive, pool_address)
            )
            && !option::is_some(
                spec_find_validator(validator_set.pending_active, pool_address)
            );
        aborts_if bool_find_validator
            && !exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        let new_withdraw_amount_1 = min(
            withdraw_amount,
            stake_pool.inactive.value + stake_pool.pending_inactive.value
        );
        let new_withdraw_amount_2 = min(withdraw_amount, stake_pool.inactive.value);
        aborts_if bool_find_validator
            && timestamp::now_seconds() > stake_pool.locked_until_secs
            && new_withdraw_amount_1 > 0
            && stake_pool.inactive.value + stake_pool.pending_inactive.value
                < new_withdraw_amount_1;
        aborts_if !(
            bool_find_validator
                && exists<timestamp::CurrentTimeMicroseconds>(@topo_framework)
        )
            && new_withdraw_amount_2 > 0
            && stake_pool.inactive.value < new_withdraw_amount_2;
        aborts_if !exists<coin::CoinStore<TopoCoin>>(addr);
        include coin::DepositAbortsIf<TopoCoin> { account_addr: addr };

        let coin_store = global<coin::CoinStore<TopoCoin>>(addr);
        let post p_coin_store = global<coin::CoinStore<TopoCoin>>(addr);
        ensures bool_find_validator
            && timestamp::now_seconds() > stake_pool.locked_until_secs
            && exists<account::Account>(addr)
            && exists<coin::CoinStore<TopoCoin>>(addr) ==>
            coin_store.coin.value + new_withdraw_amount_1 == p_coin_store.coin.value;
        ensures !(
            bool_find_validator
                && exists<timestamp::CurrentTimeMicroseconds>(@topo_framework)
        )
            && exists<account::Account>(addr)
            && exists<coin::CoinStore<TopoCoin>>(addr) ==>
            coin_store.coin.value + new_withdraw_amount_2 == p_coin_store.coin.value;
    }

    spec leave_validator_set(operator: &signer, pool_address: address) {
        pragma disable_invariants_in_body;
        requires chain_status::is_operating();
        aborts_if reconfiguration_state::spec_is_in_progress();
        let config = staking_config::get();
        aborts_if !staking_config::get_allow_validator_set_change(config);
        aborts_if !exists<StakePool>(pool_address);
        aborts_if !exists<ValidatorSet>(@topo_framework);
        aborts_if !exists<staking_config::StakingConfig>(@topo_framework);
        let stake_pool = global<StakePool>(pool_address);
        aborts_if signer::address_of(operator) != stake_pool.operator_address;

        let validator_set = global<ValidatorSet>(@topo_framework);
        let validator_find_bool = option::is_some(
            spec_find_validator(validator_set.pending_active, pool_address)
        );
        let active_validators = validator_set.active_validators;
        let pending_active = validator_set.pending_active;

        let post post_validator_set = global<ValidatorSet>(@topo_framework);
        let post post_active_validators = post_validator_set.active_validators;
        let pending_inactive_validators = validator_set.pending_inactive;
        let post post_pending_inactive_validators = post_validator_set.pending_inactive;
        ensures len(active_validators) + len(pending_inactive_validators)
            == len(post_active_validators) + len(post_pending_inactive_validators);

        aborts_if !validator_find_bool
            && !option::is_some(spec_find_validator(active_validators, pool_address));
        aborts_if !validator_find_bool
            && vector::length(validator_set.active_validators)
                <= option::borrow(spec_find_validator(active_validators, pool_address));
        aborts_if !spec_poc_enabled() && !validator_find_bool
            && vector::length(validator_set.active_validators) < 2;
        aborts_if validator_find_bool
            && vector::length(validator_set.pending_active)
                <= option::borrow(spec_find_validator(pending_active, pool_address));
        let post p_validator_set = global<ValidatorSet>(@topo_framework);
        let validator_stake = (get_voting_power(stake_pool) as u128);
        ensures !spec_poc_enabled() && validator_find_bool
            && validator_set.total_joining_power > validator_stake ==>
            p_validator_set.total_joining_power
                == validator_set.total_joining_power - validator_stake;
        ensures !validator_find_bool ==>
            !option::is_some(
                spec_find_validator(p_validator_set.pending_active, pool_address)
            );
    }

    spec extract_owner_cap(owner: &signer): OwnerCapability {
        // TODO: set because of timeout (property proved)
        pragma verify_duration_estimate = 300;
        let owner_address = signer::address_of(owner);
        aborts_if !exists<OwnerCapability>(owner_address);
        ensures !exists<OwnerCapability>(owner_address);
    }

    spec deposit_owner_cap(owner: &signer, owner_cap: OwnerCapability) {
        let owner_address = signer::address_of(owner);
        aborts_if exists<OwnerCapability>(owner_address);
        ensures exists<OwnerCapability>(owner_address);
        ensures global<OwnerCapability>(owner_address) == owner_cap;
    }

    spec unlock_with_cap(amount: u64, owner_cap: &OwnerCapability) {
        let pool_address = owner_cap.pool_address;
        let pre_stake_pool = global<StakePool>(pool_address);
        let post stake_pool = global<StakePool>(pool_address);
        aborts_if reconfiguration_state::spec_is_in_progress();
        aborts_if amount != 0 && !exists<StakePool>(pool_address);
        modifies global<StakePool>(pool_address);
        include StakedValueNochange;
        let min_amount = topo_std::math64::min(amount, pre_stake_pool.active.value);

        ensures stake_pool.active.value == pre_stake_pool.active.value - min_amount;
        ensures stake_pool.pending_inactive.value
            == pre_stake_pool.pending_inactive.value + min_amount;
    }

    // 在能力入口检查冻结状态，避免上层质押服务绕过限制延长锁仓。
    spec increase_lockup_with_cap(owner_cap: &OwnerCapability) {
        let config = global<staking_config::StakingConfig>(@topo_framework);
        let pool_address = owner_cap.pool_address;
        let pre_stake_pool = global<StakePool>(pool_address);
        let post stake_pool = global<StakePool>(pool_address);
        let now_seconds = timestamp::spec_now_seconds();
        let lockup = config.recurring_lockup_duration_secs;
        modifies global<StakePool>(pool_address);
        include StakedValueNochange;

        aborts_if reconfiguration_state::spec_is_in_progress();
        aborts_if !exists<StakePool>(pool_address);
        aborts_if pre_stake_pool.locked_until_secs >= lockup + now_seconds;
        aborts_if lockup + now_seconds > MAX_U64;
        aborts_if !exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        aborts_if !exists<staking_config::StakingConfig>(@topo_framework);

        ensures stake_pool.locked_until_secs == lockup + now_seconds;
    }

    spec update_network_and_fullnode_addresses(
        operator: &signer,
        pool_address: address,
        new_network_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    ) {
        let pre_stake_pool = global<StakePool>(pool_address);
        let post validator_info = global<ValidatorConfig>(pool_address);
        modifies global<ValidatorConfig>(pool_address);
        include StakedValueNochange;

        aborts_if reconfiguration_state::spec_is_in_progress();
        // Only the true operator address can update the network and full node addresses of the validator.
        aborts_if !exists<StakePool>(pool_address);
        aborts_if !exists<ValidatorConfig>(pool_address);
        aborts_if signer::address_of(operator) != pre_stake_pool.operator_address;

        ensures validator_info.network_addresses == new_network_addresses;
        ensures validator_info.fullnode_addresses == new_fullnode_addresses;
    }

    spec set_operator_with_cap(owner_cap: &OwnerCapability, new_operator: address) {
        let pool_address = owner_cap.pool_address;
        let post post_stake_pool = global<StakePool>(pool_address);
        modifies global<StakePool>(pool_address);
        include StakedValueNochange;

        ensures post_stake_pool.operator_address == new_operator;
    }

    spec reactivate_stake_with_cap(owner_cap: &OwnerCapability, amount: u64) {
        let pool_address = owner_cap.pool_address;
        include StakedValueNochange;

        aborts_if reconfiguration_state::spec_is_in_progress();
        aborts_if !stake_pool_exists(pool_address);

        let pre_stake_pool = global<StakePool>(pool_address);
        let post stake_pool = global<StakePool>(pool_address);
        modifies global<StakePool>(pool_address);
        let min_amount = topo_std::math64::min(
            amount, pre_stake_pool.pending_inactive.value
        );

        ensures stake_pool.pending_inactive.value
            == pre_stake_pool.pending_inactive.value - min_amount;
        ensures stake_pool.active.value == pre_stake_pool.active.value + min_amount;
    }

    spec rotate_consensus_key(
        operator: &signer,
        pool_address: address,
        new_consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>
    ) {
        let pre_stake_pool = global<StakePool>(pool_address);
        let post validator_info = global<ValidatorConfig>(pool_address);
        aborts_if reconfiguration_state::spec_is_in_progress();
        aborts_if !exists<StakePool>(pool_address);
        aborts_if signer::address_of(operator) != pre_stake_pool.operator_address;
        aborts_if !exists<ValidatorConfig>(pool_address);
        let pubkey_from_pop = bls12381::spec_public_key_from_bytes_with_pop(
            new_consensus_pubkey,
            proof_of_possession_from_bytes(proof_of_possession)
        );
        aborts_if !option::is_some(pubkey_from_pop);
        modifies global<ValidatorConfig>(pool_address);
        include StakedValueNochange;

        ensures validator_info.consensus_pubkey == new_consensus_pubkey;
    }

    spec set_delegated_voter_with_cap(owner_cap: &OwnerCapability, new_voter: address) {
        let pool_address = owner_cap.pool_address;
        let post post_stake_pool = global<StakePool>(pool_address);
        include StakedValueNochange;
        aborts_if !exists<StakePool>(pool_address);
        modifies global<StakePool>(pool_address);
        ensures post_stake_pool.delegated_voter == new_voter;
    }

    spec initialize_pending_transaction_fee {
        pragma verify = false; // TODO: set because of timeout.
        modifies global<PendingTransactionFee>(@topo_framework);
    }

    spec on_new_epoch {
        requires !exists<poc_accounting::AccountingState>(@topo_framework);
        pragma opaque;
        pragma disable_invariants_in_body;
        modifies global<ValidatorSet>(@topo_framework);
        modifies global<ValidatorPerformance>(@topo_framework);
        modifies global<PendingTransactionFee>(@topo_framework);
        // The following resource requirement cannot be discharged by the global
        // invariants because this function is called during genesis.
        include ResourceRequirement;
        include GetReconfigStartTimeRequirement;
        include staking_config::StakingRewardsConfigRequirement;
        include topo_framework::topo_coin::ExistsTopoCoin;
        // 这里只列出部分中止条件；状态错误或算术失败仍会回滚整笔事务。
        /// [high-level-req-4]
        aborts_if false;
        // Invariant: the precomputed cache is consumed (resource destroyed) so the next epoch starts fresh.
        ensures !exists<PrecomputedValidatorSet>(@topo_framework);
        // Invariant: if a precomputed validator set was present, it becomes the active set.
        ensures old(exists<PrecomputedValidatorSet>(@topo_framework)) ==>
            global<ValidatorSet>(@topo_framework).active_validators
                == old(global<PrecomputedValidatorSet>(@topo_framework)).validator_set.active_validators;
    } proof {
        split exists<PrecomputedValidatorSet>(@topo_framework);
        split features::spec_periodical_reward_rate_decrease_enabled();
    }

    /// 按区块输入顺序累计失败次数，同一索引重复出现时分别计数。
    spec fun spec_failure_count(indices: vector<u64>, validator_index: u64, end: num): num {
        if (end <= 0) { 0 } else {
            spec_failure_count(indices, validator_index, end - 1)
                + if (indices[end - 1] == validator_index) { 1 } else { 0 }
        }
    }

    spec lemma failure_count_monotonic(indices: vector<u64>, validator_index: u64, start: num, end: num) {
        requires 0 <= start && start <= end && end <= len(indices);
        ensures spec_failure_count(indices, validator_index, start)
            <= spec_failure_count(indices, validator_index, end);
    } proof {
        if (start < end) {
            apply failure_count_monotonic(indices, validator_index, start, end - 1);
            assert spec_failure_count(indices, validator_index, end - 1)
                <= spec_failure_count(indices, validator_index, end);
        }
    }

    spec update_performance_statistics {
        pragma opaque;
        pragma aborts_if_is_partial = false;
        // This function is expected to be used after genesis.
        requires chain_status::is_operating();
        modifies global<ValidatorPerformance>(@topo_framework);

        let validator_perf = global<ValidatorPerformance>(@topo_framework);
        let post post_validator_perf = global<ValidatorPerformance>(@topo_framework);
        let validator_len = len(validator_perf.validators);
        // 计数器已满仍是合法存储状态，仅再次更新该计数器时失败。
        aborts_if option::is_some(proposer_index) && option::borrow(proposer_index) < validator_len
            && validator_perf.validators[option::borrow(proposer_index)].successful_proposals == MAX_U64
            with error::OUT_OF_RANGE;
        aborts_if exists i in 0..validator_len:
            validator_perf.validators[i].failed_proposals
                + spec_failure_count(failed_proposer_indices, i, len(failed_proposer_indices)) > MAX_U64
            with error::OUT_OF_RANGE;
        ensures exists<ValidatorPerformance>(@topo_framework);
        ensures len(post_validator_perf.validators) == validator_len;
        ensures forall i in 0..validator_len:
            post_validator_perf.validators[i].failed_proposals == validator_perf.validators[i].failed_proposals
                + spec_failure_count(failed_proposer_indices, i, len(failed_proposer_indices));
        ensures forall i in 0..validator_len:
            post_validator_perf.validators[i].successful_proposals == validator_perf.validators[i].successful_proposals
                + if (option::is_some(proposer_index) && option::borrow(proposer_index) == i) { 1 } else { 0 };
    } proof {
        split option::is_some(proposer_index);
        split len(failed_proposer_indices) == 0;
        forall i: u64, x: num { spec_failure_count(failed_proposer_indices, i, x) }
            apply failure_count_monotonic(failed_proposer_indices, i, x, len(failed_proposer_indices));
    }

    spec compute_simulated_validator_info(
        candidate: &ValidatorInfo,
        validator_perf: &ValidatorPerformance,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        validator_index: u64,
        include_rewards: bool,
        cutoff_secs: u64
    ): (u64, ValidatorInfo) {
        requires rewards_rate <= staking_config::MAX_REWARDS_RATE;
        requires rewards_rate_denominator > 0;
        requires rewards_rate <= rewards_rate_denominator;
        requires include_rewards ==>
            candidate.config.validator_index < len(validator_perf.validators);
        // 两个 u64 提案计数器之和不受 u64 上限约束。
        aborts_if false;
        ensures result_2.addr == candidate.addr;
        ensures result_2.config.validator_index == validator_index;
        ensures result_2.voting_power == result_1;
    }

    spec compute_native_next_validator_set {
        pragma opaque;
        requires rewards_rate <= staking_config::MAX_REWARDS_RATE;
        requires rewards_rate_denominator > 0;
        requires rewards_rate <= rewards_rate_denominator;
        requires forall i in 0..len(global<ValidatorSet>(@topo_framework).active_validators):
            global<ValidatorSet>(@topo_framework).active_validators[i].config.validator_index
                < len(global<ValidatorPerformance>(@topo_framework).validators);
        ensures spec_target_indices(result_1);
    }

    spec next_validator_consensus_infos_v2 {
        pragma opaque;
        modifies global<PrecomputedValidatorSet>(@topo_framework);
        include !exists<poc_accounting::AccountingState>(@topo_framework) ==> ResourceRequirement;
        include !exists<poc_accounting::AccountingState>(@topo_framework) ==> GetReconfigStartTimeRequirement;
        include !exists<poc_accounting::AccountingState>(@topo_framework)
            && features::spec_periodical_reward_rate_decrease_enabled() ==>
            staking_config::StakingRewardsConfigEnabledRequirement;
        aborts_if exists<poc_accounting::AccountingState>(@topo_framework)
            && (!exists<EpochPlan>(@topo_framework) || !exists<PrecomputedValidatorSet>(@topo_framework));
        // Proof support for I2 in `reconfiguration_with_dkg::try_start*`:
        // the cache is created on first call and preserved on subsequent ones.
        ensures exists<PrecomputedValidatorSet>(@topo_framework);
        ensures result == global<PrecomputedValidatorSet>(@topo_framework).validator_set;
        ensures spec_target_indices(result);
        ensures exists<poc_accounting::AccountingState>(@topo_framework) ==>
            exists<EpochPlan>(@topo_framework) && result == spec_cached_epoch_preview().validator_set;
        ensures old(exists<PrecomputedValidatorSet>(@topo_framework)) ==>
            global<PrecomputedValidatorSet>(@topo_framework) == old(global<PrecomputedValidatorSet>(@topo_framework));
    }

    spec update_stake_pool {
        pragma opaque;
        modifies global<StakePool>(pool_address);
        modifies global<PendingTransactionFee>(@topo_framework);
        include ResourceRequirement;
        include topo_framework::topo_coin::ExistsTopoCoin;
        include GetReconfigStartTimeRequirement;
        include staking_config::StakingRewardsConfigRequirement;

        include UpdateStakePoolAbortsIf;

        let stake_pool = global<StakePool>(pool_address);
        let validator_config = global<ValidatorConfig>(pool_address);
        let cur_validator_perf = validator_perf.validators[validator_config.validator_index];
        let num_successful_proposals = cur_validator_perf.successful_proposals;
        let num_total_proposals = cur_validator_perf.successful_proposals
            + cur_validator_perf.failed_proposals;
        let rewards_rate = spec_get_reward_rate_1(staking_config);
        let rewards_rate_denominator = spec_get_reward_rate_2(staking_config);
        let rewards_amount_1 = if (stake_pool.active.value > 0) {
            spec_rewards_amount(
                stake_pool.active.value,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator
            )
        } else { 0 };
        let rewards_amount_2 = if (stake_pool.pending_inactive.value > 0) {
            spec_rewards_amount(
                stake_pool.pending_inactive.value,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator
            )
        } else { 0 };
        let fees = spec_native_distributable_fee(validator_config.validator_index);
        let voting_stake = stake_pool.active.value + stake_pool.pending_inactive.value;
        let inactive_fee = if (voting_stake > 0) {
            fees * stake_pool.pending_inactive.value / voting_stake
        } else { 0 };
        let post post_stake_pool = global<StakePool>(pool_address);
        let post post_active_value = post_stake_pool.active.value;
        let post post_pending_inactive_value = post_stake_pool.pending_inactive.value;
        let post post_inactive_value = post_stake_pool.inactive.value;
        ensures exists<StakePool>(pool_address);
        ensures exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
        ensures post_stake_pool.pending_active.value == 0;
        // 原生奖励和允许分发的费用仍计入各自对应的本金字段。
        ensures post_active_value
            == stake_pool.active.value + rewards_amount_1
                + stake_pool.pending_active.value + fees - inactive_fee;
        // when current lockup cycle has expired, pending inactive should be fully unlocked and moved into inactive
        ensures if (spec_get_reconfig_start_time_secs() >= stake_pool.locked_until_secs) {
            post_pending_inactive_value == 0
                && post_inactive_value
                    == stake_pool.inactive.value + stake_pool.pending_inactive.value
                        + rewards_amount_2 + inactive_fee
        } else {
            post_pending_inactive_value
                == stake_pool.pending_inactive.value + rewards_amount_2 + inactive_fee
        };
    } proof {
        split features::spec_periodical_reward_rate_decrease_enabled();
        split features::spec_is_enabled(features::DISTRIBUTE_TRANSACTION_FEE);
    }

    // 按旧索引、费用开关和每池限额计算原生费用分发的参考值。
    spec fun spec_native_distributable_fee(index: u64): num {
        let fees = global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
        let limit = if (exists<TransactionFeeConfig>(@topo_framework)) {
            global<TransactionFeeConfig>(@topo_framework).max_fee_octa_allowed_per_epoch_per_pool
        } else { MAX_U64 };
        if (features::spec_is_enabled(features::DISTRIBUTE_TRANSACTION_FEE)
            && exists<PendingTransactionFee>(@topo_framework)
            && big_ordered_map::spec_contains_key(fees, index)) {
            min(aggregator_v2::spec_get_value(big_ordered_map::spec_get(fees, index)), limit)
        } else { 0 }
    }

    spec refresh_validator_set_in_place {
        pragma opaque;
        ensures spec_validators_are_initialized(validator_set.active_validators);
        ensures validator_set.pending_active == old(validator_set.pending_active);
        ensures validator_set.pending_inactive == old(validator_set.pending_inactive);
    }

    spec settle_native_voters {
        pragma opaque;
        include ResourceRequirement;
        include GetReconfigStartTimeRequirement;
        include staking_config::StakingRewardsConfigRequirement;
        include topo_framework::topo_coin::ExistsTopoCoin;
        modifies global<PendingTransactionFee>(@topo_framework);
        modifies global<coin::CoinInfo<TopoCoin>>(@topo_framework);
        ensures exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
    }

    spec schema UpdateStakePoolAbortsIf {
        use topo_std::type_info;

        pool_address: address;
        validator_perf: ValidatorPerformance;

        aborts_if !exists<StakePool>(pool_address);
        aborts_if !exists<ValidatorConfig>(pool_address);
        aborts_if global<ValidatorConfig>(pool_address).validator_index
            >= len(validator_perf.validators);

        let aptos_addr = type_info::type_of<TopoCoin>().account_address;

        let stake_pool = global<StakePool>(pool_address);

        include DistributeRewardsAbortsIf { stake: stake_pool.active };
        include DistributeRewardsAbortsIf { stake: stake_pool.pending_inactive };
    }

    spec distribute_rewards {
        pragma opaque;
        pragma aborts_if_is_partial;
        include ResourceRequirement;
        requires rewards_rate <= MAX_REWARDS_RATE;
        requires rewards_rate_denominator > 0;
        requires rewards_rate <= rewards_rate_denominator;
        requires num_successful_proposals <= num_total_proposals;

        include DistributeRewardsAbortsIf;
        ensures old(exists<coin::CoinInfo<TopoCoin>>(@topo_framework)) ==>
            exists<coin::CoinInfo<TopoCoin>>(@topo_framework);

        ensures old(stake.value) > 0 ==>
            result
                == spec_rewards_amount(
                    old(stake.value),
                    num_successful_proposals,
                    num_total_proposals,
                    rewards_rate,
                    rewards_rate_denominator
                );
        ensures old(stake.value) > 0 ==>
            stake.value
                == old(stake.value)
                    + spec_rewards_amount(
                        old(stake.value),
                        num_successful_proposals,
                        num_total_proposals,
                        rewards_rate,
                        rewards_rate_denominator
                    );
        ensures old(stake.value) == 0 ==> result == 0;
        ensures old(stake.value) == 0 ==>
            stake.value == old(stake.value);
    }

    spec schema DistributeRewardsAbortsIf {
        use topo_std::type_info;

        stake: Coin<TopoCoin>;
        num_successful_proposals: num;
        num_total_proposals: num;
        rewards_rate: num;
        rewards_rate_denominator: num;

        let stake_amount = coin::value(stake);
        let rewards_amount = if (stake_amount > 0) {
            spec_rewards_amount(
                stake_amount,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator
            )
        } else { 0 };
        let addr = type_info::type_of<TopoCoin>().account_address;
        aborts_if (rewards_amount > 0) && !exists<coin::CoinInfo<TopoCoin>>(addr);
        aborts_if (rewards_amount > 0) && (stake.value + rewards_amount > MAX_U64);
        modifies global<coin::CoinInfo<TopoCoin>>(addr);
    }

    spec get_reconfig_start_time_secs(): u64 {
        include GetReconfigStartTimeRequirement;
        aborts_if false;
        ensures result == spec_get_reconfig_start_time_secs();
    }

    spec schema GetReconfigStartTimeRequirement {
        requires exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        include reconfiguration_state::spec_is_in_progress() ==>
            reconfiguration_state::StartTimeSecsRequirement;
    }

    spec fun spec_get_reconfig_start_time_secs(): u64 {
        if (reconfiguration_state::spec_is_in_progress()) {
            reconfiguration_state::spec_start_time_secs()
        } else {
            timestamp::spec_now_seconds()
        }
    }

    spec fun spec_get_lockup_secs(pool_address: address): u64 {
        global<StakePool>(pool_address).locked_until_secs
    }

    spec find_validator {
        pragma opaque;
        // Override module-level `aborts_if_is_partial` so the declared `aborts_if false` is honored.
        pragma aborts_if_is_partial = false;
        aborts_if false;
        ensures option::is_none(result) ==>
            (forall i in 0..len(v): v[i].addr != addr);
        ensures option::is_some(result) ==>
            v[option::borrow(result)].addr == addr;
        // Additional postcondition to help the quantifier instantiation.
        ensures option::is_some(result) ==>
            spec_contains(v, addr);
        ensures [abstract] result == spec_find_validator(v, addr);
    }

    spec append {
        pragma opaque, verify = false;
        aborts_if false;
        ensures len(v1) == old(len(v1) + len(v2));
        ensures len(v2) == 0;
        // The prefix of the new `v1` is the same as the old `v1`.
        ensures (forall i in 0..old(len(v1)): v1[i] == old(v1[i]));
        // The suffix of the new `v1` is the same as the reverse of the old `v2`.
        ensures (
            forall i in old(len(v1))..len(v1):
                v1[i] == old(v2[len(v2) - (i - len(v1)) - 1])
        );
    }

    spec remove_validators {
        requires chain_status::is_operating();
        let validator_set = global<ValidatorSet>(@topo_framework);
        let post post_validator_set = global<ValidatorSet>(@topo_framework);
        let active_validators = validator_set.active_validators;
        let post post_active_validators = post_validator_set.active_validators;
        let pending_inactive_validators = validator_set.pending_inactive;
        let post post_pending_inactive_validators = post_validator_set.pending_inactive;

        invariant len(active_validators) > 0;
        ensures len(active_validators) + len(pending_inactive_validators)
            == len(post_active_validators) + len(post_pending_inactive_validators);
    }

    spec is_current_epoch_validator {
        include ResourceRequirement;
        aborts_if !spec_has_stake_pool(pool_address);
        ensures result == spec_is_current_epoch_validator(pool_address);
    }

    spec get_validator_state {
        aborts_if !exists<ValidatorSet>(@topo_framework);
        let validator_set = global<ValidatorSet>(@topo_framework);
        ensures result == VALIDATOR_STATUS_PENDING_ACTIVE ==>
            spec_contains(validator_set.pending_active, pool_address);
        ensures result == VALIDATOR_STATUS_ACTIVE ==>
            spec_contains(validator_set.active_validators, pool_address);
        ensures result == VALIDATOR_STATUS_PENDING_INACTIVE ==>
            spec_contains(validator_set.pending_inactive, pool_address);
        ensures result == VALIDATOR_STATUS_INACTIVE ==>
            (
                !spec_contains(validator_set.pending_active, pool_address)
                    && !spec_contains(validator_set.active_validators, pool_address)
                    && !spec_contains(validator_set.pending_inactive, pool_address)
            );
    }

    spec add_stake_with_cap {
        pragma disable_invariants_in_body;
        pragma verify = false;
        include ResourceRequirement;
        let amount = coins.value;
        aborts_if reconfiguration_state::spec_is_in_progress();
        include AddStakeWithCapAbortsIfAndEnsures { amount };
    }

    spec add_stake {
        // TODO: fix
        pragma verify = false;
        // TODO(fa_migration)
        pragma aborts_if_is_partial;
        aborts_if reconfiguration_state::spec_is_in_progress();
        include ResourceRequirement;
        include AddStakeAbortsIfAndEnsures;
    }

    spec initialize_stake_owner(
        owner: &signer, initial_stake_amount: u64, operator: address, voter: address
    ) {
        // TODO: These function failed in github CI
        pragma verify_duration_estimate = 120;
        pragma verify = false;
        pragma aborts_if_is_partial;
        include ResourceRequirement;
        let addr = signer::address_of(owner);
        ensures global<ValidatorConfig>(addr)
            == ValidatorConfig {
                consensus_pubkey: vector::empty(),
                network_addresses: vector::empty(),
                fullnode_addresses: vector::empty(),
                validator_index: 0
            };
        ensures global<OwnerCapability>(addr) == OwnerCapability { pool_address: addr };
        let post stakepool = global<StakePool>(addr);
        let post active = stakepool.active.value;
        let post pending_active = stakepool.pending_active.value;
        ensures spec_is_current_epoch_validator(addr) ==>
            pending_active == initial_stake_amount;
        ensures !spec_is_current_epoch_validator(addr) ==>
            active == initial_stake_amount;
    }

    spec update_voting_power_increase(increase_amount: u64) {
        requires !reconfiguration_state::spec_is_in_progress();
        aborts_if !spec_poc_enabled() && !exists<ValidatorSet>(@topo_framework);
        aborts_if !spec_poc_enabled() && !exists<staking_config::StakingConfig>(@topo_framework);

        let aptos = @topo_framework;
        let pre_validator_set = global<ValidatorSet>(aptos);
        let post validator_set = global<ValidatorSet>(aptos);
        let staking_config = global<staking_config::StakingConfig>(aptos);
        let voting_power_increase_limit = staking_config.voting_power_increase_limit;
        aborts_if !spec_poc_enabled() && pre_validator_set.total_joining_power + increase_amount > MAX_U128;
        aborts_if !spec_poc_enabled() && pre_validator_set.total_voting_power > 0
            && pre_validator_set.total_voting_power * voting_power_increase_limit
                > MAX_U128;
        aborts_if !spec_poc_enabled() && pre_validator_set.total_voting_power > 0
            && pre_validator_set.total_joining_power + increase_amount
                > pre_validator_set.total_voting_power * voting_power_increase_limit
                    / 100;
        // Correctly modified total_joining_power and the value of total_voting_power is legal.
        ensures !spec_poc_enabled() && validator_set.total_voting_power > 0 ==>
            validator_set.total_joining_power
                <= validator_set.total_voting_power * voting_power_increase_limit / 100;
        ensures !spec_poc_enabled() ==> validator_set.total_joining_power
            == pre_validator_set.total_joining_power + increase_amount;
        ensures spec_poc_enabled() ==> validator_set == pre_validator_set;
    }

    spec assert_stake_pool_exists(pool_address: address) {
        aborts_if !stake_pool_exists(pool_address);
    }

    spec configure_allowed_validators(topo_framework: &signer, accounts: vector<address>) {
        let topo_framework_address = signer::address_of(topo_framework);
        aborts_if !system_addresses::is_topo_framework_address(topo_framework_address);
        let post allowed = global<AllowedValidators>(topo_framework_address);
        // Make sure that the accounts of AllowedValidators are always the passed parameter.
        ensures allowed.accounts == accounts;
    }

    spec assert_owner_cap_exists(owner: address) {
        aborts_if !exists<OwnerCapability>(owner);
    }

    spec validator_consensus_infos_from_validator_set(validator_set: &ValidatorSet): vector<
        ValidatorConsensusInfo> {
        pragma opaque;
        aborts_if false;
        requires len(validator_set.active_validators) + len(validator_set.pending_inactive) <= MAX_U64;
        invariant spec_validator_indices_are_valid_config(
            validator_set.active_validators,
            len(validator_set.active_validators) + len(validator_set.pending_inactive)
        );
        invariant len(validator_set.pending_inactive) == 0
            || spec_validator_indices_are_valid_config(
                validator_set.pending_inactive,
                len(validator_set.active_validators)
                    + len(validator_set.pending_inactive)
            );
        ensures len(result) == len(validator_set.active_validators)
            + len(validator_set.pending_inactive);
        ensures spec_target_indices(validator_set) ==>
            (forall i in 0..len(validator_set.active_validators):
                spec_consensus_info_matches(result[i], validator_set.active_validators[i]));
    }

    // DKG 输入须与目标的地址、公钥和权重一致，不能只验证向量长度。
    spec fun spec_consensus_info_matches(info: ValidatorConsensusInfo, validator: ValidatorInfo): bool {
        info.addr == validator.addr
            && info.pk_bytes == validator.config.consensus_pubkey
            && info.voting_power == validator.voting_power
    }

    // ---------------------------------
    // Spec helper functions and schemas
    // ---------------------------------

    spec schema AddStakeWithCapAbortsIfAndEnsures {
        owner_cap: OwnerCapability;
        amount: u64;

        let pool_address = owner_cap.pool_address;
        aborts_if !exists<StakePool>(pool_address);

        let config = global<staking_config::StakingConfig>(@topo_framework);
        let validator_set = global<ValidatorSet>(@topo_framework);
        let voting_power_increase_limit = config.voting_power_increase_limit;
        let post post_validator_set = global<ValidatorSet>(@topo_framework);
        let update_voting_power_increase = !spec_poc_enabled() && amount != 0
            && (
                spec_contains(validator_set.active_validators, pool_address)
                    || spec_contains(validator_set.pending_active, pool_address)
            );
        aborts_if update_voting_power_increase
            && validator_set.total_joining_power + amount > MAX_U128;
        ensures update_voting_power_increase ==>
            post_validator_set.total_joining_power
                == validator_set.total_joining_power + amount;
        aborts_if update_voting_power_increase
            && validator_set.total_voting_power > 0
            && validator_set.total_voting_power * voting_power_increase_limit
                > MAX_U128;
        aborts_if update_voting_power_increase
            && validator_set.total_voting_power > 0
            && validator_set.total_joining_power + amount
                > validator_set.total_voting_power * voting_power_increase_limit / 100;
        let stake_pool = global<StakePool>(pool_address);
        let post post_stake_pool = global<StakePool>(pool_address);
        let value_pending_active = stake_pool.pending_active.value;
        let value_active = stake_pool.active.value;
        ensures amount != 0 && spec_is_current_epoch_validator(pool_address) ==>
            post_stake_pool.pending_active.value == value_pending_active + amount;
        ensures amount != 0 && !spec_is_current_epoch_validator(pool_address) ==>
            post_stake_pool.active.value == value_active + amount;
        let maximum_stake = config.maximum_stake;
        let value_pending_inactive = stake_pool.pending_inactive.value;
        let next_epoch_voting_power = value_pending_active + value_active
            + value_pending_inactive;
        let voting_power = next_epoch_voting_power + amount;
        aborts_if amount != 0 && voting_power > MAX_U64;
        aborts_if amount != 0 && voting_power > maximum_stake;
    }

    spec schema AddStakeAbortsIfAndEnsures {
        owner: signer;
        amount: u64;

        let owner_address = signer::address_of(owner);
        aborts_if !exists<OwnerCapability>(owner_address);

        let owner_cap = global<OwnerCapability>(owner_address);
        include AddStakeWithCapAbortsIfAndEnsures { owner_cap };
    }

    spec fun spec_is_allowed(account: address): bool {
        if (!exists<AllowedValidators>(@topo_framework)) { true }
        else {
            let allowed = global<AllowedValidators>(@topo_framework);
            contains(allowed.accounts, account)
        }
    }

    spec fun spec_find_validator(v: vector<ValidatorInfo>, addr: address): Option<u64>;

    // A predicate that all given validators have been initialized.
    spec fun spec_validators_are_initialized(validators: vector<ValidatorInfo>): bool {
        forall i in 0..len(validators):
            spec_has_stake_pool(validators[i].addr)
                && spec_has_validator_config(validators[i].addr)
    }

    spec fun spec_validators_are_initialized_addrs(addrs: vector<address>): bool {
        forall i in 0..len(addrs):
            spec_has_stake_pool(addrs[i]) && spec_has_validator_config(addrs[i])
    }

    // A predicate that the validator index of each given validator in-range.
    spec fun spec_validator_indices_are_valid(validators: vector<ValidatorInfo>): bool {
        spec_validator_indices_are_valid_addr(
            validators, spec_validator_index_upper_bound()
        ) && spec_validator_indices_are_valid_config(
            validators, spec_validator_index_upper_bound()
        )
    }

    spec fun spec_validator_indices_are_valid_addr(
        validators: vector<ValidatorInfo>, upper_bound: u64
    ): bool {
        forall i in 0..len(validators):
            global<ValidatorConfig>(validators[i].addr).validator_index < upper_bound
    }

    spec fun spec_validator_indices_are_valid_config(
        validators: vector<ValidatorInfo>, upper_bound: u64
    ): bool {
        forall i in 0..len(validators):
            validators[i].config.validator_index < upper_bound
    }

    spec fun spec_validator_indices_active_pending_inactive(validator_set: ValidatorSet): bool {
        len(validator_set.pending_inactive) + len(validator_set.active_validators)
            == spec_validator_index_upper_bound()
    }

    // The upper bound of validator indices.
    spec fun spec_validator_index_upper_bound(): u64 {
        len(global<ValidatorPerformance>(@topo_framework).validators)
    }

    spec fun spec_has_stake_pool(a: address): bool {
        exists<StakePool>(a)
    }

    spec fun spec_has_validator_config(a: address): bool {
        exists<ValidatorConfig>(a)
    }

    // 用数学整数描述 u256 实现，覆盖总提案数超过 u64::MAX 的情况。
    spec fun spec_rewards_amount(
        stake_amount: num,
        num_successful_proposals: num,
        num_total_proposals: num,
        rewards_rate: num,
        rewards_rate_denominator: num
    ): num {
        if (num_total_proposals == 0) { 0 }
        else { stake_amount * rewards_rate * num_successful_proposals / (rewards_rate_denominator * num_total_proposals) }
    }

    spec fun spec_contains(validators: vector<ValidatorInfo>, addr: address): bool {
        exists i in 0..len(validators): validators[i].addr == addr
    }

    spec fun spec_is_current_epoch_validator(pool_address: address): bool {
        let validator_set = global<ValidatorSet>(@topo_framework);
        !spec_contains(validator_set.pending_active, pool_address)
            && (
                spec_contains(validator_set.active_validators, pool_address)
                    || spec_contains(validator_set.pending_inactive, pool_address)
            )
    }

    // These resources are required to successfully execute `on_new_epoch`, which cannot
    // be discharged by the global invariants because `on_new_epoch` is called in genesis.
    spec schema ResourceRequirement {
        requires exists<TopoCoinCapabilities>(@topo_framework);
        requires exists<ValidatorPerformance>(@topo_framework);
        requires exists<ValidatorSet>(@topo_framework);
        requires exists<StakingConfig>(@topo_framework);
        requires exists<StakingRewardsConfig>(@topo_framework)
            || !features::spec_periodical_reward_rate_decrease_enabled();
        requires exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
    }

    // Adding helper function in staking_config leads to an unexpected error
    // So we write two helper functions here to model function staking_config::get_reward_rate().
    spec fun spec_get_reward_rate_1(config: StakingConfig): num {
        if (features::spec_periodical_reward_rate_decrease_enabled()) {
            let epoch_rewards_rate =
                global<staking_config::StakingRewardsConfig>(@topo_framework).rewards_rate;
            if (epoch_rewards_rate.value == 0) { 0 }
            else {
                let denominator_0 =
                    topo_std::fixed_point64::spec_divide_u128(
                        staking_config::MAX_REWARDS_RATE, epoch_rewards_rate
                    );
                let denominator =
                    if (denominator_0 > MAX_U64) {
                        MAX_U64
                    } else {
                        denominator_0
                    };
                let nominator =
                    topo_std::fixed_point64::spec_multiply_u128(
                        denominator, epoch_rewards_rate
                    );
                nominator
            }
        } else {
            config.rewards_rate
        }
    }

    spec fun spec_get_reward_rate_2(config: StakingConfig): num {
        if (features::spec_periodical_reward_rate_decrease_enabled()) {
            let epoch_rewards_rate =
                global<staking_config::StakingRewardsConfig>(@topo_framework).rewards_rate;
            if (epoch_rewards_rate.value == 0) { 1 }
            else {
                let denominator_0 =
                    topo_std::fixed_point64::spec_divide_u128(
                        staking_config::MAX_REWARDS_RATE, epoch_rewards_rate
                    );
                let denominator =
                    if (denominator_0 > MAX_U64) {
                        MAX_U64
                    } else {
                        denominator_0
                    };
                denominator
            }
        } else {
            config.rewards_rate_denominator
        }
    }

    spec get_pending_transaction_fee {
        pragma verify = false;
    }

    // 根据资源是否存在及已安装的上下文确定模式，不用计划启用时间推断。
    spec fun spec_poc_enabled(): bool {
        exists<poc_accounting::AccountingState>(@topo_framework)
            && exists<InstalledRewardContext>(@topo_framework)
            && global<InstalledRewardContext>(@topo_framework).context.poc_enabled
    }

    spec is_poc_enabled {
        ensures result == spec_poc_enabled();
    }

    spec get_installed_reward_rate {
        include !exists<poc_accounting::AccountingState>(@topo_framework) ==>
            staking_config::StakingRewardsConfigRequirement;
    }

    spec reward_context {
        include staking_config::StakingRewardsConfigRequirement;
    }

    spec set_transaction_fee_config {
        include exists<poc_accounting::AccountingState>(@topo_framework) ==>
            staking_config::StakingRewardsConfigRequirement;
    }

    spec set_transaction_fee_limit_per_epoch_per_pool {
        include exists<poc_accounting::AccountingState>(@topo_framework) ==>
            staking_config::StakingRewardsConfigRequirement;
    }

    spec RewardContext {
        invariant rewards_rate_denominator > 0;
        invariant rewards_rate <= rewards_rate_denominator;
        invariant rewards_rate <= staking_config::MAX_REWARDS_RATE;
    }

    spec EpochPreview {
        invariant spec_target_indices(validator_set);
    }

    spec PrecomputedValidatorSet {
        invariant spec_target_indices(validator_set);
    }

    // 公开预览仍由同一份冻结数据构成，委员会及回退标记只取自 PVS。
    spec fun spec_cached_epoch_preview(): EpochPreview {
        let data = global<EpochPlan>(@topo_framework).data;
        let pvs = global<PrecomputedValidatorSet>(@topo_framework);
        EpochPreview {
            reason: 0,
            epoch: data.epoch, period: data.period, period_index: data.period_index,
            cutoff_secs: data.cutoff_secs, poc_enabled: data.poc_enabled, params: data.params,
            closing_rewards: data.closing_rewards, targets: data.targets,
            validator_set: pvs.validator_set, is_liveness_fallback: pvs.is_liveness_fallback,
        }
    }

    spec cached_epoch_preview {
        requires exists<EpochPlan>(@topo_framework) && exists<PrecomputedValidatorSet>(@topo_framework);
        ensures result == spec_cached_epoch_preview();
    }

    // 目标集合只保留在任队列，索引与最终入选顺序一一对应。
    spec fun spec_target_indices(set: ValidatorSet): bool {
        len(set.pending_active) == 0 && len(set.pending_inactive) == 0
            && (forall i in 0..len(set.active_validators):
                set.active_validators[i].config.validator_index == i)
    }

    spec reward_amount_wide {
        pragma opaque;
        requires denominator > 0;
        requires rate <= denominator;
        requires success <= total;
        ensures total == 0 ==> result == 0;
        ensures total > 0 ==> result == base * rate * success / (denominator * total);
        ensures result <= base;
    }

    spec split_native_reward_by_stake {
        pragma opaque;
        requires active_stake_octa + pending_inactive_stake_octa > 0 || native_reward_octa == 0;
        ensures result_1 + result_2 == native_reward_octa;
        ensures active_stake_octa + pending_inactive_stake_octa > 0 ==>
            result_2 == native_reward_octa * pending_inactive_stake_octa / (active_stake_octa + pending_inactive_stake_octa);
        ensures active_stake_octa == 0 ==> result_1 == 0;
        ensures pending_inactive_stake_octa == 0 ==> result_2 == 0;
    }

    spec validate_current_set {
        pragma opaque;
        ensures forall i in 0..len(set.active_validators):
            set.active_validators[i].config.validator_index
                < len(global<ValidatorPerformance>(@topo_framework).validators);
    }

    spec validate_epoch_plan {
        pragma opaque;
        ensures exists<EpochPlan>(@topo_framework) && exists<PrecomputedValidatorSet>(@topo_framework);
        ensures global<EpochPlan>(@topo_framework).stage < 2;
        ensures target_epoch == global<poc_accounting::AccountingState>(@topo_framework).epoch + 1;
        ensures global<EpochPlan>(@topo_framework).data.epoch == target_epoch;
        ensures global<EpochPlan>(@topo_framework).data.closing_rewards
            == global<InstalledRewardContext>(@topo_framework).context;
        ensures global<EpochPlan>(@topo_framework).data.closing_rewards.epoch
            == global<poc_accounting::AccountingState>(@topo_framework).epoch;
        ensures spec_cached_epoch_preview().validator_set
            == global<PrecomputedValidatorSet>(@topo_framework).validator_set;
        ensures spec_cached_epoch_preview().reason == 0;
        ensures reconfiguration_state::spec_is_in_progress();
        ensures exists<features::PendingFeatureFreeze>(@std);
    }

    spec cached_validator_set {
        pragma opaque;
        aborts_if !exists<EpochPlan>(@topo_framework) || !exists<PrecomputedValidatorSet>(@topo_framework);
        ensures exists<EpochPlan>(@topo_framework) && exists<PrecomputedValidatorSet>(@topo_framework);
        ensures result == global<PrecomputedValidatorSet>(@topo_framework).validator_set;
        ensures result == spec_cached_epoch_preview().validator_set;
        ensures spec_target_indices(result);
    }

    spec preview_transition {
        pragma opaque;
        include staking_config::StakingRewardsConfigRequirement;
        ensures result.epoch == target_epoch;
        ensures result.cutoff_secs == cutoff_secs;
        ensures result.closing_rewards == global<InstalledRewardContext>(@topo_framework).context;
        ensures result.poc_enabled == (
            option::spec_is_some(global<poc_accounting::AccountingState>(@topo_framework).config.first_poc_epoch)
                || target_epoch >= global<poc_accounting::AccountingState>(@topo_framework).config.activation_epoch);
    }

    spec preview_epoch_transition {
        include staking_config::StakingRewardsConfigRequirement;
        ensures exists<EpochPlan>(@topo_framework) ==> result == spec_cached_epoch_preview();
    }

    spec allocate_growth {
        pragma opaque;
        requires len(candidates) == len(bases);
        requires increase_limit <= 50;
        ensures len(result) == len(candidates);
        ensures forall i in 0..len(result): result[i] <= candidates[i];
        ensures first ==> result == candidates;
    }

    spec prepare_poc_context {
        include staking_config::StakingRewardsConfigRequirement;
        modifies global<InstalledRewardContext>(@topo_framework);
        modifies global<PendingTransactionFee>(@topo_framework);
        modifies global<VoluntaryLeaves>(@topo_framework);
        modifies global<poc_reward_split::RewardSplitConfig>(@topo_framework);
        ensures exists<InstalledRewardContext>(@topo_framework);
        ensures global<InstalledRewardContext>(@topo_framework).context.epoch == epoch;
        ensures !global<InstalledRewardContext>(@topo_framework).context.poc_enabled;
    }

    // 缓存时保持旧账本、委员会和奖励上下文；只有 Ready 才创建计划和 PVS，并冻结配置。
    spec try_cache_epoch_plan {
        pragma opaque;
        include staking_config::StakingRewardsConfigRequirement;
        modifies global<EpochPlan>(@topo_framework);
        modifies global<PrecomputedValidatorSet>(@topo_framework);
        modifies global<features::PendingFeatureFreeze>(@std);
        ensures global<poc_accounting::AccountingState>(@topo_framework)
            == old(global<poc_accounting::AccountingState>(@topo_framework));
        ensures global<InstalledRewardContext>(@topo_framework)
            == old(global<InstalledRewardContext>(@topo_framework));
        ensures global<ValidatorSet>(@topo_framework) == old(global<ValidatorSet>(@topo_framework));
        ensures result == 0 ==> exists<EpochPlan>(@topo_framework)
            && exists<PrecomputedValidatorSet>(@topo_framework)
            && exists<features::PendingFeatureFreeze>(@std);
        ensures result == 0 ==> global<EpochPlan>(@topo_framework).data.epoch == target_epoch;
        ensures result == 0 ==> global<EpochPlan>(@topo_framework).data.closing_rewards
            == global<InstalledRewardContext>(@topo_framework).context;
        ensures result == 0 ==> spec_cached_epoch_preview().validator_set
            == global<PrecomputedValidatorSet>(@topo_framework).validator_set;
        ensures result == 0 ==> spec_cached_epoch_preview().reason == 0;
        ensures result == 0 ==> global<EpochPlan>(@topo_framework).stage < 2;
        ensures old(exists<EpochPlan>(@topo_framework)) ==>
            global<EpochPlan>(@topo_framework) == old(global<EpochPlan>(@topo_framework))
                && global<PrecomputedValidatorSet>(@topo_framework)
                    == old(global<PrecomputedValidatorSet>(@topo_framework));
        ensures result == 0 && !old(exists<EpochPlan>(@topo_framework)) ==>
            global<EpochPlan>(@topo_framework).stage == 0
                && global<EpochPlan>(@topo_framework).data.cutoff_secs == cutoff_secs;
        ensures result == 0 && !old(exists<EpochPlan>(@topo_framework)) ==>
            global<EpochPlan>(@topo_framework).data.poc_enabled == (
                option::spec_is_some(global<poc_accounting::AccountingState>(@topo_framework).config.first_poc_epoch)
                    || target_epoch >= global<poc_accounting::AccountingState>(@topo_framework).config.activation_epoch);
        ensures result != 0 ==> !exists<EpochPlan>(@topo_framework)
            && !exists<PrecomputedValidatorSet>(@topo_framework);
        ensures result != 0 ==> exists<features::PendingFeatureFreeze>(@std)
            == old(exists<features::PendingFeatureFreeze>(@std));
    }

    // 奖励结算完成后推进计划阶段，保留旧 Epoch 和目标预览供后续安装使用。
    spec settle_closing_epoch {
        pragma opaque;
        modifies global<EpochPlan>(@topo_framework);
        modifies global<PendingTransactionFee>(@topo_framework);
        ensures global<EpochPlan>(@topo_framework).stage == 1;
        ensures global<EpochPlan>(@topo_framework).data == old(global<EpochPlan>(@topo_framework)).data;
        ensures global<PrecomputedValidatorSet>(@topo_framework) == old(global<PrecomputedValidatorSet>(@topo_framework));
        ensures spec_cached_epoch_preview() == old(spec_cached_epoch_preview());
        ensures global<InstalledRewardContext>(@topo_framework) == old(global<InstalledRewardContext>(@topo_framework));
        ensures global<ValidatorSet>(@topo_framework) == old(global<ValidatorSet>(@topo_framework));
        ensures global<poc_accounting::AccountingState>(@topo_framework).epoch
            == old(global<poc_accounting::AccountingState>(@topo_framework)).epoch;
    }

    spec take_epoch_fee {
        modifies global<PendingTransactionFee>(@topo_framework);
        ensures result <= context.fee_limit_per_pool;
        ensures !context.distribute_transaction_fee ==> result == 0;
    }

    spec settle_voting_pool {
        pragma opaque;
        modifies global<PendingTransactionFee>(@topo_framework);
        modifies global<StakePool>(v.addr);
        modifies global<poc_accounting::AccountingState>(@topo_framework);
        ensures global<poc_accounting::AccountingState>(@topo_framework).epoch
            == old(global<poc_accounting::AccountingState>(@topo_framework)).epoch;
        ensures global<poc_accounting::AccountingState>(@topo_framework).config
            == old(global<poc_accounting::AccountingState>(@topo_framework)).config;
    }

    spec apply_stake_transitions {
        modifies global<StakePool>(pool);
        ensures global<StakePool>(pool).pending_active.value == 0;
        ensures old(global<StakePool>(pool)).locked_until_secs <= cutoff_secs ==>
            global<StakePool>(pool).pending_inactive.value == 0;
    }

    spec install_epoch_plan {
        pragma opaque;
        // 在同一事务内重建表现数组和验证者索引，安装委员会后恢复二者的关联不变量。
        pragma disable_invariants_in_body;
        include staking_config::StakingRewardsConfigRequirement;
        modifies global<EpochPlan>(@topo_framework);
        modifies global<InstalledRewardContext>(@topo_framework);
        modifies global<poc_reward_split::RewardSplitConfig>(@topo_framework);
        modifies global<ValidatorSet>(@topo_framework);
        modifies global<ValidatorPerformance>(@topo_framework);
        modifies global<PendingTransactionFee>(@topo_framework);
        modifies global<VoluntaryLeaves>(@topo_framework);
        modifies global<poc_accounting::AccountingState>(@topo_framework);
        modifies global<poc_power_store::PowerStore>(@topo_framework);
        modifies global<poc_power_store::PeriodClock>(@topo_framework);
        // 安装会推进周期和指数，但不更换算力上传者或周期长度配置。
        ensures exists<poc_power_store::PowerStore>(@topo_framework);
        ensures exists<poc_power_store::PeriodClock>(@topo_framework);
        ensures global<poc_power_store::PowerStore>(@topo_framework).operator
            == old(global<poc_power_store::PowerStore>(@topo_framework)).operator;
        ensures global<poc_power_store::PeriodClock>(@topo_framework).power_period_in_epochs
            == old(global<poc_power_store::PeriodClock>(@topo_framework)).power_period_in_epochs;
        ensures exists<EpochPlan>(@topo_framework) && exists<ValidatorSet>(@topo_framework);
        ensures exists<InstalledRewardContext>(@topo_framework)
            && exists<poc_accounting::AccountingState>(@topo_framework);
        ensures global<EpochPlan>(@topo_framework).stage == 2;
        ensures global<EpochPlan>(@topo_framework).data == old(global<EpochPlan>(@topo_framework)).data;
        ensures global<PrecomputedValidatorSet>(@topo_framework) == old(global<PrecomputedValidatorSet>(@topo_framework));
        ensures spec_cached_epoch_preview() == old(spec_cached_epoch_preview());
        ensures global<ValidatorSet>(@topo_framework) == old(global<PrecomputedValidatorSet>(@topo_framework)).validator_set;
        ensures global<InstalledRewardContext>(@topo_framework).context.epoch == target_epoch;
        ensures target_epoch == old(global<poc_accounting::AccountingState>(@topo_framework)).epoch + 1;
        ensures global<InstalledRewardContext>(@topo_framework).context.epoch == old(global<EpochPlan>(@topo_framework)).data.epoch;
        ensures global<InstalledRewardContext>(@topo_framework).context.poc_enabled == old(global<EpochPlan>(@topo_framework)).data.poc_enabled;
        ensures global<poc_accounting::AccountingState>(@topo_framework).epoch == old(global<EpochPlan>(@topo_framework)).data.epoch;
    } proof {
        split global<EpochPlan>(@topo_framework).data.poc_enabled;
        split features::spec_periodical_reward_rate_decrease_enabled();
    }

    // 收尾时同时移除计划、PVS 和标准库冻结状态，防止重复使用缓存。
    spec finish_epoch_plan {
        pragma opaque;
        modifies global<EpochPlan>(@topo_framework);
        modifies global<PrecomputedValidatorSet>(@topo_framework);
        modifies global<features::PendingFeatureFreeze>(@std);
        ensures !exists<EpochPlan>(@topo_framework);
        ensures !exists<PrecomputedValidatorSet>(@topo_framework);
        ensures !exists<features::PendingFeatureFreeze>(@std);
    }

    spec cancel_leave_validator_set {
        ensures global<ValidatorSet>(@topo_framework).total_voting_power == old(global<ValidatorSet>(@topo_framework)).total_voting_power;
        ensures global<ValidatorConfig>(pool) == old(global<ValidatorConfig>(pool));
        ensures global<ValidatorPerformance>(@topo_framework) == old(global<ValidatorPerformance>(@topo_framework));
    }
}
