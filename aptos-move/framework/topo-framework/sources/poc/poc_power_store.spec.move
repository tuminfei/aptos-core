spec topo_framework::poc_power_store {
    // 列明初始化可修改的资源，保证上层流程依赖的其他模块状态不变。
    spec initialize {
        pragma aborts_if_is_partial = true;
        modifies global<PowerStore>(@topo_framework);
        modifies global<PeriodClock>(@topo_framework);
        ensures exists<PowerStore>(@topo_framework) && exists<PeriodClock>(@topo_framework);
        ensures global<PowerStore>(@topo_framework).operator == power_operator;
        ensures global<PowerStore>(@topo_framework).retention_bps_per_period == retention_bps;
        ensures global<PowerStore>(@topo_framework).normalization.baseline_epoch == epoch;
        ensures global<PowerStore>(@topo_framework).normalization.current_index == INDEX_SCALE;
        ensures global<PowerStore>(@topo_framework).normalization.max_relative_period == max_relative_period;
        ensures global<PeriodClock>(@topo_framework).last_epoch == 0;
        ensures global<PeriodClock>(@topo_framework).current_period == 0;
        ensures global<PeriodClock>(@topo_framework).epochs_until_next_power_period == power_period_in_epochs;
        ensures global<PeriodClock>(@topo_framework).power_period_in_epochs == power_period_in_epochs;
    }

    // 换届只推进周期与指数，保留治理配置；显式列明修改位置供安装计划的规格调用。
    spec commit_next_period_if_boundary {
        modifies global<PowerStore>(@topo_framework);
        modifies global<PeriodClock>(@topo_framework);
        ensures exists<PowerStore>(@topo_framework) && exists<PeriodClock>(@topo_framework);
        ensures global<PowerStore>(@topo_framework).operator
            == old(global<PowerStore>(@topo_framework)).operator;
        ensures global<PeriodClock>(@topo_framework).power_period_in_epochs
            == old(global<PeriodClock>(@topo_framework)).power_period_in_epochs;
    }

    // 验证每个算力周期的整数取整结果，不用实数幂近似衰减。
    spec decayed_index {
        requires index <= INDEX_SCALE;
        requires retention_bps <= BPS_DENOMINATOR;
        aborts_if false;
        ensures result == index * retention_bps / BPS_DENOMINATOR;
        ensures result <= index;
    }

    // 下一指数可用必须同时满足周期期限和指数下界。
    spec supported_next_index {
        requires index <= INDEX_SCALE;
        requires retention_bps <= BPS_DENOMINATOR;
        aborts_if false;
        let next = index * retention_bps / BPS_DENOMINATOR;
        ensures option::is_some(result) <==> period < max_period && next >= MIN_PERIOD_INDEX;
        ensures option::is_some(result) ==> option::borrow(result) == next;
        ensures option::is_some(result) ==> MIN_PERIOD_INDEX <= option::borrow(result)
            && option::borrow(result) <= index;
    }

    // 标准化保留版本的生效算力周期与原始算力，并证明 units 转为 u128 前满足上界。
    spec normalized_version {
        aborts_if index < MIN_PERIOD_INDEX;
        ensures result.effective_period == effective_period;
        ensures result.power == power;
        ensures result.units == power * UNIT_SCALE * INDEX_SCALE / index;
        ensures result.units < MAX_VERSION_UNITS;
    }

    // 保留比例只在 PowerStore 保存，初始化后没有修改入口。
    spec PowerStore {
        invariant retention_bps_per_period > 0 && retention_bps_per_period <= BPS_DENOMINATOR;
    }

    // 嵌入的标准化状态保持有效指数范围。
    spec NormalizationState {
        invariant current_index >= MIN_PERIOD_INDEX && current_index <= INDEX_SCALE;
        invariant option::is_some(next_index) ==> MIN_PERIOD_INDEX <= option::borrow(next_index)
            && option::borrow(next_index) <= current_index;
    }

    // 新用户零值不新增；已有用户的有效零版本仍允许写入。
    spec will_insert_version {
        pragma aborts_if_is_partial = true;
        let has_user = table::spec_contains(store.users, user);
        let info = table::spec_get(store.users, user);
        ensures result == if (has_user) {
            (option::is_none(info.older) || option::borrow(info.older).effective_period != period)
                && (option::is_none(info.newer) || option::borrow(info.newer).effective_period != period)
        } else { power > 0 };
    }

    // 保存调用者构造的完整双槽，原始算力与 units 不存在分开写入的状态。
    spec save_power_versions {
        let post written = table::spec_get(store.users, user);
        aborts_if option::is_none(versions.newer) with error::INVALID_STATE;
        aborts_if option::is_some(versions.older) && option::is_some(versions.newer)
            && option::borrow(versions.older).effective_period >= option::borrow(versions.newer).effective_period
            with error::INVALID_STATE;
        ensures table::spec_contains(store.users, user);
        ensures written == versions;
        ensures option::is_some(written.newer);
        ensures option::is_some(written.older) ==>
            option::borrow(written.older).effective_period < option::borrow(written.newer).effective_period;
    }
}
