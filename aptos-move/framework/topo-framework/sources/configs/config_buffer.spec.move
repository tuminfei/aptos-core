spec topo_framework::config_buffer {
    spec module {
        pragma verify = true;
    }

    spec initialize(topo_framework: &signer) {
        use std::signer;
        pragma opaque;
        let addr = signer::address_of(topo_framework);
        aborts_if addr != @topo_framework;
        modifies global<PendingConfigs>(@topo_framework);
        ensures exists<PendingConfigs>(@topo_framework);
        ensures !old(exists<PendingConfigs>(@topo_framework)) ==>
            simple_map::spec_len(global<PendingConfigs>(@topo_framework).configs) == 0;
        ensures old(exists<PendingConfigs>(@topo_framework)) ==>
            global<PendingConfigs>(@topo_framework) == old(global<PendingConfigs>(@topo_framework));
    }

    spec does_exist<T: store>(): bool {
        pragma opaque;
        aborts_if false;
        let type_name = type_info::type_name<T>();
        ensures result == spec_fun_does_exist<T>(type_name);
    }

    spec fun spec_fun_does_exist<T: store>(type_name: String): bool {
        if (exists<PendingConfigs>(@topo_framework)) {
            let config = global<PendingConfigs>(@topo_framework);
            simple_map::spec_contains_key(config.configs, type_name)
        } else {
            false
        }
    }

    spec upsert<T: drop + store>(config: T) {
        pragma opaque;
        aborts_if reconfiguration_state::spec_is_in_progress();
        include Upsert<T>;
    }

    spec upsert_session_result<T: drop + store>(config: T) {
        pragma opaque;
        aborts_if !reconfiguration_state::spec_is_in_progress();
        include Upsert<T>;
    }

    spec upsert_internal<T: drop + store>(config: T) {
        pragma opaque;
        include Upsert<T>;
    }

    spec schema Upsert<T: drop + store> {
        config: T;
        aborts_if !exists<PendingConfigs>(@topo_framework);
        modifies global<PendingConfigs>(@topo_framework);

        let key = type_info::type_name<T>();
        let configs_pre = global<PendingConfigs>(@topo_framework).configs;
        let post configs_post = global<PendingConfigs>(@topo_framework).configs;
        ensures exists<PendingConfigs>(@topo_framework);
        // 写入会话密钥时仅修改对应缓冲项，其他已冻结配置必须保持不变。
        ensures spec_without(configs_post, key) == spec_without(configs_pre, key);
        ensures simple_map::spec_contains_key(configs_post, key);
        ensures simple_map::spec_get(configs_post, key) == any::pack(config);
    }

    spec extract_v2<T: store>(): T {
        use topo_std::from_bcs;
        pragma opaque;
        aborts_if !exists<PendingConfigs>(@topo_framework);
        include ExtractAbortsIf<T>;
        modifies global<PendingConfigs>(@topo_framework);
        let key = type_info::type_name<T>();
        let pre_configs = global<PendingConfigs>(@topo_framework).configs;
        let stored = simple_map::spec_get(pre_configs, key);
        let post post_configs = global<PendingConfigs>(@topo_framework).configs;
        ensures result == from_bcs::deserialize<T>(stored.data);
        ensures post_configs == simple_map::spec_remove(pre_configs, key);
        ensures !simple_map::spec_contains_key(post_configs, key);
        ensures exists<PendingConfigs>(@topo_framework);
        include BufferConsumed { first_key: key, second_key: key };
    }

    spec schema ExtractAbortsIf<T> {
        let configs = global<PendingConfigs>(@topo_framework);
        let key = type_info::type_name<T>();
        aborts_if !simple_map::spec_contains_key(configs.configs, key);
        include any::UnpackAbortsIf<T> {
            self: simple_map::spec_get(configs.configs, key)
        };
    }

    spec schema SetForNextEpochAbortsIf {
        account: &signer;
        config: vector<u8>;
        let account_addr = std::signer::address_of(account);
        aborts_if account_addr != @topo_framework;
        aborts_if len(config) == 0;
        aborts_if !exists<PendingConfigs>(@topo_framework);
        aborts_if reconfiguration_state::spec_is_in_progress();
    }

    spec schema OnNewEpochRequirement<T> {
        use topo_std::type_info;
        let type_name = type_info::type_name<T>();
        let configs = global<PendingConfigs>(@topo_framework);
        include spec_fun_does_exist<T>(type_name) ==> any::UnpackRequirement<T> {
            self: simple_map::spec_get(configs.configs, type_name)
        };
    }

    /// 在规格中模拟按 key 移除缓冲项；key 不存在时保持原映射，供多个安装入口组合使用。
    spec fun spec_without(configs: SimpleMap<String, Any>, key: String): SimpleMap<String, Any> {
        if (simple_map::spec_contains_key(configs, key)) {
            simple_map::spec_remove(configs, key)
        } else {
            configs
        }
    }

    // 仅移除一项的入口将同一 key 传入两次；移除不存在的 key 不改变映射，
    // 与运行代码先检查 does_exist 的行为一致。
    spec schema BufferConsumed {
        first_key: String;
        second_key: String;
        let had_buffer = exists<PendingConfigs>(@topo_framework);
        let configs_pre = global<PendingConfigs>(@topo_framework).configs;
        let post configs_post = global<PendingConfigs>(@topo_framework).configs;
        ensures exists<PendingConfigs>(@topo_framework) == had_buffer;
        ensures had_buffer ==> configs_post == spec_without(spec_without(configs_pre, first_key), second_key);
    }

    spec schema OnNewEpochApply<T> {
        framework: &signer;
        include OnNewEpochApplyResource<T>;
        include BufferConsumed {
            first_key: type_info::type_name<T>(), second_key: type_info::type_name<T>()
        };
    }

    spec schema OnNewEpochApplyPair<T, U> {
        framework: &signer;
        include OnNewEpochApplyResource<T>;
        include OnNewEpochApplyResource<U>;
        include BufferConsumed {
            first_key: type_info::type_name<T>(), second_key: type_info::type_name<U>()
        };
    }

    spec schema OnNewEpochApplyResource<T> {
        use topo_std::from_bcs;
        use topo_std::simple_map;
        use topo_std::type_info;
        framework: &signer;

        requires @topo_framework == std::signer::address_of(framework);
        modifies global<PendingConfigs>(@topo_framework);
        modifies global<T>(@topo_framework);

        let pending_configs = global<PendingConfigs>(@topo_framework);
        let pending_configs_exists = exists<PendingConfigs>(@topo_framework);
        let key = type_info::type_name<T>();
        let had = pending_configs_exists
            && simple_map::spec_contains_key(pending_configs.configs, key);
        let stored = simple_map::spec_get(pending_configs.configs, key);
        aborts_if had && stored.type_name != key;
        aborts_if had && !from_bcs::deserializable<T>(stored.data);
        let extracted = from_bcs::deserialize<T>(
            simple_map::spec_get(pending_configs.configs, key).data);
        ensures had ==> global<T>(@topo_framework) == extracted;
    }

    spec schema SetForNextEpoch<T: drop + store> {
        framework: &signer;
        new_config: T;

        modifies global<PendingConfigs>(@topo_framework);
        aborts_if aborts_of<system_addresses::assert_topo_framework>(framework);
        aborts_if aborts_of<upsert<T>>(new_config);
        ensures ensures_of<upsert<T>>(new_config);
    }

    spec schema InitializeResource<T> {
        framework: &signer;
        config: T;

        modifies global<T>(@topo_framework);
        aborts_if aborts_of<system_addresses::assert_topo_framework>(framework);
        ensures !old(exists<T>(@topo_framework)) ==>
            global<T>(@topo_framework) == config;
    }
}
