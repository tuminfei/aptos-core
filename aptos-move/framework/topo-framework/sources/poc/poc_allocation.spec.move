spec topo_framework::poc_allocation {
    // 准备完成后，各模块对齐同一个链 Epoch；当前 Epoch 仍使用原生计奖上下文。
    spec prepare_poc {
        pragma opaque;
        pragma aborts_if_is_partial = true;
        include staking_config::StakingRewardsConfigRequirement;
        let epoch = global<reconfiguration::Configuration>(@topo_framework).epoch;
        let post state = global<poc_accounting::AccountingState>(@topo_framework);
        modifies global<config_buffer::PendingConfigs>(@topo_framework);
        modifies global<poc_accounting::AccountingState>(@topo_framework);
        modifies global<poc_power_store::PowerStore>(@topo_framework);
        modifies global<poc_power_store::PeriodClock>(@topo_framework);
        modifies global<stake::InstalledRewardContext>(@topo_framework);
        modifies global<stake::VoluntaryLeaves>(@topo_framework);
        modifies global<stake::PendingTransactionFee>(@topo_framework);
        aborts_if std::signer::address_of(framework) != @topo_framework;
        aborts_if !topo_framework::reconfiguration_state::is_initialized();
        ensures exists<poc_accounting::AccountingState>(@topo_framework);
        ensures state.epoch == epoch;
        ensures state.config.params == params && state.config.limits == limits;
        ensures state.config.activation_epoch == activation_epoch;
        ensures state.config.deployment_mode == deployment_mode;
        ensures std::option::spec_is_none(state.config.first_poc_epoch);
        ensures std::option::spec_is_none(state.config.pending_params);
        // 一次初始化同时创建算力表与时钟；向创世和运行期调用方保留这些已验证的初始事实。
        ensures exists<poc_power_store::PowerStore>(@topo_framework);
        ensures exists<poc_power_store::PeriodClock>(@topo_framework);
        ensures global<poc_power_store::PowerStore>(@topo_framework).operator == power_operator;
        ensures global<poc_power_store::PeriodClock>(@topo_framework).power_period_in_epochs
            == power_period_in_epochs;
        ensures !exists<stake::EpochPlan>(@topo_framework);
        ensures !exists<stake::PrecomputedValidatorSet>(@topo_framework);
        ensures exists<stake::InstalledRewardContext>(@topo_framework);
        ensures global<stake::InstalledRewardContext>(@topo_framework).context.epoch == epoch;
        ensures !global<stake::InstalledRewardContext>(@topo_framework).context.poc_enabled;
    }

    // 池准入只建立账本，不改变全局 Epoch 或已安装参数。
    spec enable_pool {
        pragma opaque;
        pragma aborts_if_is_partial = true;
        modifies global<poc_accounting::AccountingState>(@topo_framework);
        aborts_if std::signer::address_of(framework) != @topo_framework;
        aborts_if !topo_framework::stake::stake_pool_exists(pool);
        ensures exists<poc_accounting::AccountingState>(@topo_framework);
        ensures global<poc_accounting::AccountingState>(@topo_framework).epoch
            == old(global<poc_accounting::AccountingState>(@topo_framework)).epoch;
        ensures global<poc_accounting::AccountingState>(@topo_framework).config
            == old(global<poc_accounting::AccountingState>(@topo_framework)).config;
    }

    // 用户分配只读取算力快照并重建持仓，不能改写算力版本、推进 Epoch 或修改全局配置。
    spec set_allocations {
        pragma opaque;
        pragma aborts_if_is_partial;
        modifies global<poc_accounting::AccountingState>(@topo_framework);
        modifies global<poc_accounting::UserAllocation>(signer::address_of(user));
        ensures exists<poc_accounting::AccountingState>(@topo_framework);
        ensures global<poc_accounting::AccountingState>(@topo_framework).epoch
            == old(global<poc_accounting::AccountingState>(@topo_framework)).epoch;
        ensures global<poc_accounting::AccountingState>(@topo_framework).config
            == old(global<poc_accounting::AccountingState>(@topo_framework)).config;
    }
}
