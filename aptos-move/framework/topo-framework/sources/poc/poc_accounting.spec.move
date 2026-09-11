spec topo_framework::poc_accounting {
    // 这里约束账本结构和整数运算，不假定 Epoch 的实际持续时间有上限。
    // 出块表现计数和选举输入由 stake 模块的规格约束。
    spec Position {
        invariant units <= MAX_POOL_UNITS;
        invariant len(changes) <= 2;
        invariant len(changes) == 2 ==> changes[0].epoch < changes[1].epoch;
    }

    spec PoolLedger {
        invariant units <= MAX_POOL_UNITS;
        invariant len(changes) <= 2;
        invariant len(changes) == 2 ==> changes[0].epoch < changes[1].epoch;
        invariant forall i in 0..len(changes): changes[i].epoch > epoch;
        invariant forall i in 0..len(changes): changes[i].refs > 0;
        invariant reward_epoch <= epoch;
    }

    spec pool_power {
        aborts_if units > MAX_POOL_UNITS;
        aborts_if period_index < MIN_PERIOD_INDEX || period_index > INDEX_SCALE;
        ensures result == units * period_index / (UNIT_SCALE * INDEX_SCALE);
    }

    spec allocated_units {
        pragma opaque;
        aborts_if version_units * bps / BPS_DENOMINATOR > MAX_POOL_UNITS;
        ensures result == version_units * bps / BPS_DENOMINATOR;
        ensures result <= MAX_POOL_UNITS;
        ensures bps <= BPS_DENOMINATOR ==> result <= version_units;
    }

    spec advance_pool {
        ensures ledger.epoch == epoch;
        ensures ledger.reward_epoch == old(ledger.reward_epoch);
        ensures ledger.reward_base_octa == old(ledger.reward_base_octa);
        ensures ledger.index == old(ledger.index);
        ensures ledger.vault == old(ledger.vault);
    }

    // 对共享的分段计算完整描述指数回退和 u256 乘加溢出，查询与落盘沿用同一整数公式。
    spec accrued_at {
        aborts_if index < cursor;
        aborts_if index >= cursor && accrued + units * (index - cursor) > Q * Q - 1;
        ensures result == accrued + units * (index - cursor);
        ensures result >= accrued;
    }

    spec settle_position {
        ensures ledger.epoch == old(ledger.epoch);
    }

    // 推进全局 Epoch 时只安装到期参数并记录首次 PoC Epoch；池记录由逐池提交接口更新。
    spec advance_epoch {
        pragma opaque;
        let before = global<AccountingState>(@topo_framework);
        let config = before.config;
        let first = if (option::spec_is_some(config.first_poc_epoch)) {
            option::spec_borrow(config.first_poc_epoch)
        } else { epoch };
        let end = first + config.limits.reward_epoch_limit;
        let apply_params = option::spec_is_some(config.pending_params)
            && option::spec_borrow(config.pending_params).epoch <= epoch;
        let post after = global<AccountingState>(@topo_framework);
        modifies global<AccountingState>(@topo_framework);
        aborts_if !exists<AccountingState>(@topo_framework);
        aborts_if poc_enabled != (option::spec_is_some(config.first_poc_epoch) || epoch >= config.activation_epoch);
        aborts_if poc_enabled && (end > MAX_U64 || epoch < first || epoch >= end);
        aborts_if epoch != before.epoch + 1;
        ensures exists<AccountingState>(@topo_framework);
        ensures after.epoch == epoch;
        ensures after.pools == before.pools;
        ensures after.config.activation_epoch == config.activation_epoch;
        ensures after.config.deployment_mode == config.deployment_mode;
        ensures after.config.limits == config.limits;
        ensures after.config.params == if (apply_params) {
            option::spec_borrow(config.pending_params).params
        } else { config.params };
        ensures after.config.pending_params == if (apply_params) {
            option::spec_none<PendingPowerParams>()
        } else { config.pending_params };
        ensures after.config.first_poc_epoch == if (poc_enabled && option::spec_is_none(config.first_poc_epoch)) {
            option::spec_some(epoch)
        } else { config.first_poc_epoch };
    }

    spec install_pool_target {
        // 这里只列出部分中止条件；advance_pool 仍会因容量或检查点损坏而中止。
        pragma opaque, aborts_if_is_partial;
        let before = global<AccountingState>(@topo_framework);
        let ledger = table::spec_get(before.pools, pool);
        let post after = global<AccountingState>(@topo_framework);
        let post target = table::spec_get(after.pools, pool);
        modifies global<AccountingState>(@topo_framework);
        aborts_if !exists<AccountingState>(@topo_framework);
        aborts_if epoch != before.epoch + 1;
        aborts_if reward_base_octa > before.config.limits.max_reward_base_octa;
        aborts_if !table::spec_contains(before.pools, pool);
        ensures exists<AccountingState>(@topo_framework);
        ensures after.epoch == before.epoch && after.config == before.config;
        ensures target.epoch == epoch && target.units == units && target.reward_base_octa == reward_base_octa;
        ensures target.reward_epoch == ledger.reward_epoch;
        ensures target.index == ledger.index && target.vault == ledger.vault;
        ensures forall p: address: table::spec_contains(after.pools, p) == table::spec_contains(before.pools, p);
        ensures forall p: address where p != pool && table::spec_contains(before.pools, p):
            table::spec_get(after.pools, p) == table::spec_get(before.pools, p);
    }

    // 入账只改变指定池的金库、奖励指数及已入账的 Epoch，保留当前 Epoch 的 units 和未来变化。
    spec credit_epoch_reward {
        pragma opaque, aborts_if_is_partial;
        let before = global<AccountingState>(@topo_framework);
        let ledger = table::spec_get(before.pools, pool);
        let delta = if (ledger.units == 0) { 0 } else { reward.value * Q / ledger.units };
        let post after = global<AccountingState>(@topo_framework);
        let post target = table::spec_get(after.pools, pool);
        modifies global<AccountingState>(@topo_framework);
        aborts_if !exists<AccountingState>(@topo_framework);
        aborts_if before.epoch != epoch || option::spec_is_none(before.config.first_poc_epoch);
        aborts_if !table::spec_contains(before.pools, pool);
        aborts_if ledger.epoch != epoch || ledger.reward_epoch >= epoch;
        aborts_if ledger.units == 0 && reward.value != 0;
        ensures exists<AccountingState>(@topo_framework);
        ensures after.epoch == before.epoch && after.config == before.config;
        ensures result == delta && target.index == ledger.index + delta;
        ensures target.vault.value == ledger.vault.value + reward.value;
        ensures target.reward_epoch == epoch;
        ensures target.epoch == ledger.epoch && target.units == ledger.units;
        ensures target.changes == ledger.changes && target.checkpoints == ledger.checkpoints;
        ensures target.reward_base_octa == ledger.reward_base_octa;
        ensures forall p: address: table::spec_contains(after.pools, p) == table::spec_contains(before.pools, p);
        ensures forall p: address where p != pool && table::spec_contains(before.pools, p):
            table::spec_get(after.pools, p) == table::spec_get(before.pools, p);
    }

    spec prepare {
        pragma opaque, aborts_if_is_partial;
        let post state = global<AccountingState>(@topo_framework);
        modifies global<AccountingState>(@topo_framework);
        aborts_if signer::address_of(framework) != @topo_framework;
        aborts_if exists<AccountingState>(@topo_framework);
        ensures exists<AccountingState>(@topo_framework);
        ensures state.epoch == epoch && state.config.activation_epoch == activation_epoch;
        ensures state.config.params == params && state.config.limits == limits;
        ensures state.config.deployment_mode == deployment_mode;
        ensures option::spec_is_none(state.config.pending_params);
        ensures option::spec_is_none(state.config.first_poc_epoch);
        ensures forall pool: address: !table::spec_contains(state.pools, pool);
    }

    spec enable_pool {
        pragma opaque, aborts_if_is_partial;
        let before = global<AccountingState>(@topo_framework);
        let post after = global<AccountingState>(@topo_framework);
        let post ledger = table::spec_get(after.pools, pool);
        modifies global<AccountingState>(@topo_framework);
        aborts_if signer::address_of(framework) != @topo_framework;
        aborts_if !exists<AccountingState>(@topo_framework);
        aborts_if table::spec_contains(before.pools, pool);
        ensures exists<AccountingState>(@topo_framework);
        ensures after.epoch == before.epoch && after.config == before.config;
        ensures table::spec_contains(after.pools, pool);
        ensures ledger.epoch == before.epoch && ledger.units == 0 && len(ledger.changes) == 0;
        ensures ledger.reward_base_octa == 0 && ledger.index == 0 && ledger.vault.value == 0;
        ensures ledger.reward_epoch == if (before.epoch > 0) { before.epoch - 1 } else { 0 };
        ensures forall e: u64: !table::spec_contains(ledger.checkpoints, e);
        ensures forall p: address where p != pool:
            table::spec_contains(after.pools, p) == table::spec_contains(before.pools, p);
        ensures forall p: address where p != pool && table::spec_contains(before.pools, p):
            table::spec_get(after.pools, p) == table::spec_get(before.pools, p);
    }

    // 重建允许修改用户和池的记账状态，但全局 Epoch 与配置始终保持不变。
    spec rebuild_user {
        pragma opaque, aborts_if_is_partial;
        modifies global<AccountingState>(@topo_framework);
        modifies global<UserAllocation>(user);
        ensures exists<AccountingState>(@topo_framework);
        ensures exists<UserAllocation>(user);
        ensures global<AccountingState>(@topo_framework).epoch == old(global<AccountingState>(@topo_framework).epoch);
        ensures global<AccountingState>(@topo_framework).config == old(global<AccountingState>(@topo_framework).config);
    }

    spec rebuild_user_pool {
        pragma opaque, aborts_if_is_partial;
        requires boundary_epoch > state.epoch;
        ensures state.epoch == old(state.epoch) && state.config == old(state.config);
        ensures allocation.active == old(allocation.active);
        ensures allocation.pending == old(allocation.pending);
    }

    spec replace_allocation {
        pragma opaque, aborts_if_is_partial;
        modifies global<AccountingState>(@topo_framework);
        modifies global<UserAllocation>(signer::address_of(user));
        ensures exists<AccountingState>(@topo_framework);
        ensures exists<UserAllocation>(signer::address_of(user));
        ensures global<AccountingState>(@topo_framework).epoch == old(global<AccountingState>(@topo_framework).epoch);
        ensures global<AccountingState>(@topo_framework).config == old(global<AccountingState>(@topo_framework).config);
    }

    spec fun sorted_shadows(shadows: vector<PoolShadow>): bool {
        forall i in 0..len(shadows), j in 0..len(shadows):
            i < j ==> shadows[i].epoch < shadows[j].epoch
    }

    spec fun sorted_position_changes(changes: vector<PositionChange>): bool {
        forall i in 0..len(changes), j in 0..len(changes):
            i < j ==> changes[i].epoch < changes[j].epoch
    }

    spec shadow_at {
        requires sorted_shadows(shadows);
        ensures sorted_shadows(shadows);
        ensures result.epoch == epoch;
    }

    spec rebuild_position {
        // 唯一调用者已将池推进到 E，并传入 E+1 与 B > E；这里沿用真实调用前提。
        requires next_epoch > ledger.epoch;
        requires boundary_epoch >= next_epoch;
    }

    spec append_position_change {
        requires sorted_shadows(shadows);
        requires sorted_position_changes(changes);
        requires forall i in 0..len(changes): changes[i].epoch < epoch;
        ensures sorted_shadows(shadows);
        ensures sorted_position_changes(changes);
        ensures forall i in 0..len(changes): changes[i].epoch <= epoch;
    }

    spec fun spec_valid_params(
        params: PowerParams, limits: DeploymentLimits, mode: u8,
        increase_limit: num, dynamic_membership: bool,
    ): bool {
        (mode == CONTROLLED || mode == OPEN)
            && params.bond_octa_per_ohmp > 0 && params.min_power > 0
            && params.min_power <= params.max_power && params.min_validators > 0
            && params.min_validators <= limits.validator_limit
            && increase_limit > 0 && increase_limit <= 50
            && MAX_VALIDATOR_SET_SIZE * params.max_power <= MAX_U64
            && params.max_power * params.bond_octa_per_ohmp / POWER_PER_OHMP <= limits.max_reward_base_octa
            && (!dynamic_membership || (params.min_validators < limits.validator_limit
                && params.min_validators * params.min_power * increase_limit / 100 >= params.min_power))
            && (mode != OPEN || params.min_validators >= 4)
    }

    // 配置更新时复用同一组合约束；准备前使用原生校验，准备后还须检查当前及待生效 PoC 参数。
    spec fun spec_valid_native_config(increase_limit: num, dynamic_membership: bool): bool {
        let config = global<AccountingState>(@topo_framework).config;
        !exists<AccountingState>(@topo_framework) || (
            spec_valid_params(config.params, config.limits, config.deployment_mode,
                increase_limit, dynamic_membership)
            && (!option::spec_is_some(config.pending_params)
                || spec_valid_params(option::spec_borrow(config.pending_params).params,
                    config.limits, config.deployment_mode, increase_limit, dynamic_membership)))
    }

    spec fun spec_valid_reward_rate(numerator: num, denominator: num): bool {
        let limits = global<AccountingState>(@topo_framework).config.limits;
        !exists<AccountingState>(@topo_framework)
            || (denominator > 0 && numerator * limits.rate_max_den <= limits.rate_max_num * denominator)
    }

    spec fun spec_valid_fixed_reward_rate(raw: num): bool {
        let limits = global<AccountingState>(@topo_framework).config.limits;
        !exists<AccountingState>(@topo_framework)
            || raw * limits.rate_max_den <= limits.rate_max_num * INDEX_SCALE
    }

    spec fun spec_valid_fee_limit(value: num): bool {
        !exists<AccountingState>(@topo_framework)
            || value <= global<AccountingState>(@topo_framework).config.limits.fee_max
    }

    spec validate_params {
        aborts_if !spec_valid_params(params, limits, mode, increase_limit, dynamic_membership);
    }

    spec validate_config {
        let config = global<AccountingState>(@topo_framework).config;
        aborts_if !exists<AccountingState>(@topo_framework);
        aborts_if !spec_valid_params(params, config.limits, config.deployment_mode,
            increase_limit, dynamic_membership);
    }

    spec validate_native_config {
        aborts_if !spec_valid_native_config(increase_limit, dynamic_membership);
    }

    spec validate_reward_rate {
        aborts_if !spec_valid_reward_rate(num, den);
    }

    spec validate_fixed_reward_rate {
        aborts_if !spec_valid_fixed_reward_rate(raw);
    }

    spec validate_fee_limit {
        aborts_if !spec_valid_fee_limit(value);
    }

    spec validate_reward_config {
        aborts_if !spec_valid_reward_rate(num, den) || !spec_valid_fee_limit(fee_limit);
    }

    spec is_prepared {
        aborts_if false;
        ensures result == exists<AccountingState>(@topo_framework);
    }

    spec current_epoch {
        aborts_if !exists<AccountingState>(@topo_framework);
        ensures result == global<AccountingState>(@topo_framework).epoch;
    }
}
