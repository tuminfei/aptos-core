/// 用户签名授权分配与领取，治理签名授权 PoC 准备和参数管理。
/// 资产、持仓和部署参数统一由 poc_accounting 保存；本模块负责权限检查并协调各模块调用。
module topo_framework::poc_allocation {
    use std::error;
    use std::features;
    use std::signer;
    use topo_framework::chunky_dkg;
    use topo_framework::coin;
    use topo_framework::config_buffer;
    use topo_framework::decryption;
    use topo_framework::dkg;
    use topo_framework::event;
    use topo_framework::poc_accounting::{Self, PowerParams, DeploymentLimits};
    use topo_framework::poc_power_store;
    use topo_framework::reconfiguration;
    use topo_framework::reconfiguration_state;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::system_addresses;
    use topo_framework::topo_coin::TopoCoin;

    const EPOOL_NOT_REGISTERED: u64 = 1;
    const EUNCLEAN_TRANSITION: u64 = 2;

    #[event]
    struct PoCPrepared has drop, store {
        baseline_epoch: u64,
        baseline_source_period: u64,
        activation_epoch: u64,
        deployment_mode: u8,
    }

    /// 治理脚本明确提供完整部署清单，确认没有遗留换届计划或会话后，再建立准备状态。
    /// 部署参数不能默认沿用旧链配置；账本、当前 Epoch 的原生计奖上下文和标准化基线在同一事务初始化。
    public fun prepare_poc(
        framework: &signer,
        params: PowerParams,
        limits: DeploymentLimits,
        deployment_mode: u8,
        activation_epoch: u64,
        retention_bps: u64,
        max_relative_period: u64,
        power_period_in_epochs: u64,
        power_operator: address,
    ) {
        system_addresses::assert_topo_framework(framework);
        assert!(reconfiguration_state::is_initialized(), error::invalid_state(EUNCLEAN_TRANSITION));
        poc_accounting::assert_not_frozen();
        assert!(!features::is_reconfiguration_frozen(), error::invalid_state(EUNCLEAN_TRANSITION));
        let epoch = reconfiguration::current_epoch();
        assert!(dkg::incomplete_session().is_none() && chunky_dkg::incomplete_session().is_none()
            && !dkg::is_session_started(epoch) && !chunky_dkg::is_session_started(epoch)
            && !decryption::has_pending_epoch_key(), error::invalid_state(EUNCLEAN_TRANSITION));
        config_buffer::initialize(framework);
        let config = staking_config::get();
        poc_accounting::prepare(framework, epoch, activation_epoch, params, limits, deployment_mode,
            staking_config::get_voting_power_increase_limit(&config),
            staking_config::get_allow_validator_set_change(&config));
        // 同时拒绝遗留的原生 PVS 或孤立 PoC 计划，并保存当前 Epoch 的奖励率与费用配置。
        stake::prepare_poc_context(framework, epoch);
        poc_power_store::initialize(framework, epoch, retention_bps,
            max_relative_period, power_period_in_epochs, power_operator);
        event::emit(PoCPrepared {
            baseline_epoch: epoch,
            baseline_source_period: poc_power_store::get_current_period(),
            activation_epoch,
            deployment_mode,
        });
    }

    /// 治理仅为已注册的验证者池开放 PoC 分配；贡献应用注册表不承担验证者准入。
    public entry fun enable_pool(framework: &signer, pool: address) {
        system_addresses::assert_topo_framework(framework);
        poc_accounting::assert_not_frozen();
        assert!(stake::stake_pool_exists(pool) && stake::validator_registered(pool),
            error::invalid_argument(EPOOL_NOT_REGISTERED));
        poc_accounting::enable_pool(framework, pool);
    }

    /// 根据已写入的算力版本快照重建下一 Epoch 的分配；尚无算力的用户按零份额配置。
    public entry fun set_allocations(user: &signer, pools: vector<address>, bps: vector<u64>) {
        poc_accounting::assert_not_frozen();
        let address = signer::address_of(user);
        let (current_units, next_units, _, boundary) = poc_power_store::get_accounting_snapshot(address);
        poc_accounting::replace_allocation(user, pools, bps, current_units, next_units, boundary);
    }

    /// 冻结期间可领取已入账的历史奖励；不触发版本同步或推进下一 Epoch。
    /// 注册代币接收存储后，将奖励存入本人账户；任一步失败都回滚整笔交易。
    public entry fun claim_rewards(user: &signer, pools: vector<address>) {
        let rewards = poc_accounting::claim_rewards(user, pools);
        coin::register<TopoCoin>(user);
        coin::deposit_with_signer(user, rewards);
    }

    /// 读取原生增长配置，由账本联合校验 PoC 参数；新参数最早在下一 Epoch 生效。
    public fun schedule_power_params(framework: &signer, params: PowerParams, epoch: u64) {
        system_addresses::assert_topo_framework(framework);
        let config = staking_config::get();
        poc_accounting::schedule_power_params(framework, params, epoch,
            staking_config::get_voting_power_increase_limit(&config),
            staking_config::get_allow_validator_set_change(&config));
    }

    /// 治理可撤销未安装参数，用于修复换届预检失败；冻结时拒绝变更。
    public entry fun cancel_pending_power_params(framework: &signer) {
        poc_accounting::cancel_pending_power_params(framework);
    }

    /// 首次启用前可调整激活 Epoch，保留原有基线和已准备的用户分配。
    public entry fun reschedule_activation(framework: &signer, epoch: u64) {
        poc_accounting::reschedule_activation(framework, epoch);
    }

}
