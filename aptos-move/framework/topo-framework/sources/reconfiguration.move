/// Publishes configuration information for validators, and issues reconfiguration events
/// to synchronize configuration changes for the validators.
module topo_framework::reconfiguration {
    use std::error;
    use std::signer;

    use topo_framework::account;
    use topo_framework::event;
    use topo_framework::stake;
    use topo_framework::system_addresses;
    use topo_framework::timestamp;
    use topo_framework::chain_status;
    use topo_framework::reconfiguration_state;
    use topo_framework::storage_gas;

    friend topo_framework::topo_governance;
    friend topo_framework::block;
    friend topo_framework::consensus_config;
    friend topo_framework::execution_config;
    friend topo_framework::gas_schedule;
    friend topo_framework::genesis;
    friend topo_framework::version;
    friend topo_framework::reconfiguration_with_dkg;

    #[event]
    /// Event that signals consensus to start a new epoch,
    /// with new configuration information. This is also called a
    /// "reconfiguration event"
    struct NewEpochEvent has drop, store {
        epoch: u64
    }

    #[event]
    /// Event that signals consensus to start a new epoch,
    /// with new configuration information. This is also called a
    /// "reconfiguration event"
    struct NewEpoch has drop, store {
        epoch: u64
    }

    /// Holds information about state of reconfiguration
    struct Configuration has key {
        /// Epoch number
        epoch: u64,
        /// Time of last reconfiguration. Only changes on reconfiguration events.
        last_reconfiguration_time: u64,
        /// Event handle for reconfiguration events
        events: event::EventHandle<NewEpochEvent>
    }

    /// Reconfiguration will be disabled if this resource is published under the
    /// topo_framework system address
    struct DisableReconfiguration has key {}

    /// The `Configuration` resource is in an invalid state
    const ECONFIGURATION: u64 = 1;
    /// A `Reconfiguration` resource is in an invalid state
    const ECONFIG: u64 = 2;
    /// A `ModifyConfigCapability` is in a different state than was expected
    const EMODIFY_CAPABILITY: u64 = 3;
    /// An invalid block time was encountered.
    const EINVALID_BLOCK_TIME: u64 = 4;
    /// An invalid block time was encountered.
    const EINVALID_GUID_FOR_EVENT: u64 = 5;
    const ETRANSITION_DEFERRED: u64 = 6;

    /// Only called during genesis.
    /// Publishes `Configuration` resource. Can only be invoked by aptos framework account, and only a single time in Genesis.
    public(friend) fun initialize(topo_framework: &signer) {
        system_addresses::assert_topo_framework(topo_framework);

        // assert it matches `new_epoch_event_key()`, otherwise the event can't be recognized
        assert!(
            account::get_guid_next_creation_num(signer::address_of(topo_framework)) == 2,
            error::invalid_state(EINVALID_GUID_FOR_EVENT)
        );
        move_to<Configuration>(
            topo_framework,
            Configuration {
                epoch: 0,
                last_reconfiguration_time: 0,
                events: account::new_event_handle<NewEpochEvent>(topo_framework)
            }
        );
    }

    /// Private function to temporarily halt reconfiguration.
    /// This function should only be used for offline WriteSet generation purpose and should never be invoked on chain.
    fun disable_reconfiguration(topo_framework: &signer) {
        system_addresses::assert_topo_framework(topo_framework);
        assert!(reconfiguration_enabled(), error::invalid_state(ECONFIGURATION));
        move_to(topo_framework, DisableReconfiguration {})
    }

    /// Private function to resume reconfiguration.
    /// This function should only be used for offline WriteSet generation purpose and should never be invoked on chain.
    fun enable_reconfiguration(topo_framework: &signer) acquires DisableReconfiguration {
        system_addresses::assert_topo_framework(topo_framework);

        assert!(!reconfiguration_enabled(), error::invalid_state(ECONFIGURATION));
        DisableReconfiguration {} = move_from<DisableReconfiguration>(
            signer::address_of(topo_framework)
        );
    }

    fun reconfiguration_enabled(): bool {
        !exists<DisableReconfiguration>(@topo_framework)
    }

    /// 构建计划前检查是否允许换届，排除创世、停用重配置和同一时间戳下的重复调用。
    public(friend) fun transition_allowed(): bool acquires Configuration {
        !chain_status::is_genesis()
            && timestamp::now_microseconds() != 0
            && reconfiguration_enabled()
            && timestamp::now_microseconds() != last_reconfiguration_time()
    }

    /// 预检通过后缓存目标并冻结配置；目标不合格时返回 false，保留旧委员会和 Epoch。
    public(friend) fun prepare_transition(): bool acquires Configuration {
        if (!transition_allowed()) { return false };
        if (stake::is_poc_prepared()) {
            let epoch = current_epoch();
            if (epoch == 18446744073709551615) { return false };
            if (stake::try_cache_epoch_plan(epoch + 1, timestamp::now_seconds()) != 0) {
                return false
            };
        };
        reconfiguration_state::on_reconfig_start();
        true
    }

    /// 配置与治理入口要求换届成功；预检失败会回滚同一事务中此前的配置写入。
    public(friend) fun reconfigure() acquires Configuration {
        if (!transition_allowed()) { return };
        assert!(try_reconfigure(), error::invalid_state(ETRANSITION_DEFERRED));
    }

    /// 未准备 PoC 时沿用原生换届；准备后须改用统一换届流程，以完整安装缓冲配置。
    public(friend) fun try_reconfigure(): bool acquires Configuration {
        if (stake::is_poc_prepared()) { return false };
        if (!prepare_transition()) { return false };
        stake::on_new_epoch();
        complete_epoch(false);
        true
    }

    /// 调用前须按旧上下文结算奖励并应用缓冲配置；此处校验并安装原计划，不重新选举。
    public(friend) fun complete_prepared_transition() acquires Configuration {
        stake::install_epoch_plan(current_epoch() + 1);
        complete_epoch(true);
    }

    /// 创世时仅安装一次 Epoch 1，随后由原有创世事件流程更新 Configuration。
    public(friend) fun install_genesis_poc_epoch(framework: &signer) acquires Configuration {
        system_addresses::assert_topo_framework(framework);
        chain_status::assert_genesis();
        assert!(current_epoch() == 0, error::invalid_state(ECONFIGURATION));
        assert!(stake::try_cache_epoch_plan(1, timestamp::now_seconds()) == 0,
            error::invalid_state(ETRANSITION_DEFERRED));
        reconfiguration_state::on_reconfig_start();
        stake::settle_closing_epoch();
        stake::apply_cached_features(framework);
        stake::install_epoch_plan(1);
        stake::finish_epoch_plan();
        reconfiguration_state::on_reconfig_finish();
    }

    /// 委员会安装成功后推进链 Epoch、发出事件，再清理计划并解除冻结。
    fun complete_epoch(prepared: bool) acquires Configuration {
        storage_gas::on_reconfig();
        let current_time = timestamp::now_microseconds();
        let config_ref = borrow_global_mut<Configuration>(@topo_framework);
        assert!(current_time > config_ref.last_reconfiguration_time,
            error::invalid_state(EINVALID_BLOCK_TIME));
        config_ref.last_reconfiguration_time = current_time;
        config_ref.epoch += 1;
        event::emit(NewEpoch { epoch: config_ref.epoch });
        event::emit_event<NewEpochEvent>(
            &mut config_ref.events, NewEpochEvent { epoch: config_ref.epoch }
        );
        if (prepared) { stake::finish_epoch_plan() };
        reconfiguration_state::on_reconfig_finish();
    }

    public fun last_reconfiguration_time(): u64 acquires Configuration {
        borrow_global<Configuration>(@topo_framework).last_reconfiguration_time
    }

    public fun current_epoch(): u64 acquires Configuration {
        borrow_global<Configuration>(@topo_framework).epoch
    }

    /// Emit a `NewEpochEvent` event. This function will be invoked by genesis directly to generate the very first
    /// reconfiguration event.
    fun emit_genesis_reconfiguration_event() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@topo_framework);
        assert!(
            config_ref.epoch == 0 && config_ref.last_reconfiguration_time == 0,
            error::invalid_state(ECONFIGURATION)
        );
        config_ref.epoch = 1;

        event::emit(NewEpoch { epoch: config_ref.epoch });
        event::emit_event<NewEpochEvent>(
            &mut config_ref.events,
            NewEpochEvent { epoch: config_ref.epoch }
        );
    }

    /// 仅供测试复用真实创世事件流程，验证初始 Epoch 只推进一次。
    #[test_only]
    public fun emit_genesis_event_for_test() acquires Configuration {
        emit_genesis_reconfiguration_event();
    }

    // 测试初始化跳过 GUID 校验。
    #[test_only]
    public fun initialize_for_test(account: &signer) {
        system_addresses::assert_topo_framework(account);
        move_to<Configuration>(
            account,
            Configuration {
                epoch: 0,
                last_reconfiguration_time: 0,
                events: account::new_event_handle<NewEpochEvent>(account)
            }
        );
    }

    #[test_only]
    public fun reconfigure_for_test() acquires Configuration {
        reconfigure();
    }

    // This is used together with stake::end_epoch() for testing with last_reconfiguration_time
    // It must be called each time an epoch changes
    #[test_only]
    public fun reconfigure_for_test_custom() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@topo_framework);
        let current_time = timestamp::now_microseconds();
        if (current_time == config_ref.last_reconfiguration_time) { return };
        config_ref.last_reconfiguration_time = current_time;
        config_ref.epoch += 1;
    }
}
