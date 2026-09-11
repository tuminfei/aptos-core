/// This wrapper helps store an on-chain config for the next epoch.
///
/// Once reconfigure with DKG is introduced, every on-chain config `C` should do the following.
/// - Support async update when DKG is enabled. This is typically done by 3 steps below.
///   - Implement `C::set_for_next_epoch()` using `upsert()` function in this module.
///   - Implement `C::on_new_epoch()` using `extract()` function in this module.
///   - Update `0x1::reconfiguration_with_dkg::finish()` to call `C::on_new_epoch()`.
/// - Support sychronous update when DKG is disabled.
///   This is typically done by implementing `C::set()` to update the config resource directly.
///
/// NOTE: on-chain config `0x1::state::ValidatorSet` implemented its own buffer.
module topo_framework::config_buffer {
    use std::error;
    use std::string::String;
    use topo_std::any;
    use topo_std::any::Any;
    use topo_std::simple_map;
    use topo_std::simple_map::SimpleMap;
    use topo_std::type_info;
    use topo_framework::system_addresses;
    use topo_framework::reconfiguration_state;

    friend topo_framework::chunky_dkg_config;
    friend topo_framework::chunky_dkg_config_seqnum;
    friend topo_framework::consensus_config;
    friend topo_framework::decryption;
    friend topo_framework::epoch_timeout_config;
    friend topo_framework::execution_config;
    friend topo_framework::gas_schedule;
    friend topo_framework::jwks;
    friend topo_framework::jwk_consensus_config;
    friend topo_framework::keyless_account;
    friend topo_framework::randomness_api_v0_config;
    friend topo_framework::randomness_config;
    friend topo_framework::randomness_config_seqnum;
    friend topo_framework::version;

    /// Config buffer operations failed with permission denied.
    const ESTD_SIGNER_NEEDED: u64 = 1;

    /// Function is deprecated.
    const EDEPRECATED: u64 = 2;

    struct PendingConfigs has key {
        configs: SimpleMap<String, Any>,
    }

    public fun initialize(topo_framework: &signer) {
        system_addresses::assert_topo_framework(topo_framework);
        if (!exists<PendingConfigs>(@topo_framework)) {
            move_to(topo_framework, PendingConfigs {
                configs: simple_map::new(),
            })
        }
    }

    /// Check whether there is a pending config payload for `T`.
    public fun does_exist<T: store>(): bool acquires PendingConfigs {
        if (exists<PendingConfigs>(@topo_framework)) {
            let config = borrow_global<PendingConfigs>(@topo_framework);
            config.configs.contains_key(&type_info::type_name<T>())
        } else {
            false
        }
    }

    /// 将下一 Epoch 的配置写入缓冲；计划冻结后禁止替换配置内容。
    public(friend) fun upsert<T: drop + store>(config: T) acquires PendingConfigs {
        reconfiguration_state::assert_not_in_progress();
        upsert_internal(config);
    }

    /// 供 DKG 完成流程在冻结期间写入目标 Epoch 的密钥；调用前须校验会话身份及目标。
    /// 普通配置设置仍须调用 upsert，不能经此入口绕过冻结检查。
    public(friend) fun upsert_session_result<T: drop + store>(config: T) acquires PendingConfigs {
        assert!(reconfiguration_state::is_in_progress(), error::invalid_state(ESTD_SIGNER_NEEDED));
        upsert_internal(config);
    }

    /// 仅替换指定类型的缓冲项，保留其他已冻结配置；权限由两个上层入口分别检查。
    fun upsert_internal<T: drop + store>(config: T) acquires PendingConfigs {
        let configs = borrow_global_mut<PendingConfigs>(@topo_framework);
        let key = type_info::type_name<T>();
        let value = any::pack(config);
        if (configs.configs.contains_key(&key)) {
            *configs.configs.borrow_mut(&key) = value;
        } else {
            configs.configs.add(key, value);
        };
    }

    #[deprecated]
    /// Use `extract_v2` instead.
    public fun extract<T: store>(): T {
        abort(error::unavailable(EDEPRECATED))
    }

    /// Take the buffered config `T` out (buffer cleared). Abort if the buffer is empty.
    /// Should only be used at the end of a reconfiguration.
    ///
    /// Typically used in `X::on_new_epoch()` where X is an on-chaon config.
    public(friend) fun extract_v2<T: store>(): T acquires PendingConfigs {
        let configs = borrow_global_mut<PendingConfigs>(@topo_framework);
        let key = type_info::type_name<T>();
        let (_, value_packed) = configs.configs.remove(&key);
        value_packed.unpack()
    }

    #[test_only]
    struct DummyConfig has drop, store {
        data: u64,
    }

    #[test_only]
    struct OtherConfig has drop, store {
        data: u64,
    }

    #[test(fx = @std)]
    fun test_config_buffer_preserves_other_payloads(fx: &signer) acquires PendingConfigs {
        initialize(fx);
        upsert(DummyConfig { data: 1 });
        upsert(OtherConfig { data: 2 });
        upsert(DummyConfig { data: 3 });
        assert!(borrow_global<PendingConfigs>(@topo_framework).configs.keys()
            == vector[type_info::type_name<DummyConfig>(), type_info::type_name<OtherConfig>()], 1);
        assert!(extract_v2<DummyConfig>().data == 3, 2);
        assert!(extract_v2<OtherConfig>().data == 2, 3);
        assert!(!does_exist<DummyConfig>() && !does_exist<OtherConfig>(), 4);
    }

    #[test(fx = @std)]
    fun test_config_buffer_basic(fx: &signer) acquires PendingConfigs {
        initialize(fx);
        // Initially nothing in the buffer.
        assert!(!does_exist<DummyConfig>(), 1);

        // Insert should work.
        upsert(DummyConfig { data: 888 });
        assert!(does_exist<DummyConfig>(), 1);

        // Update and extract should work.
        upsert(DummyConfig { data: 999 });
        assert!(does_exist<DummyConfig>(), 1);
        let config = extract_v2<DummyConfig>();
        assert!(config == DummyConfig { data: 999 }, 1);
        assert!(!does_exist<DummyConfig>(), 1);
    }
}
