module topo_framework::randomness_api_v0_config {
    use std::option::Option;
    use topo_framework::chain_status;
    use topo_framework::config_buffer;
    use topo_framework::system_addresses;
    use topo_framework::reconfiguration_state;
    friend topo_framework::reconfiguration_with_dkg;

    struct RequiredGasDeposit has key, drop, store {
        gas_amount: Option<u64>,
    }

    /// If this flag is set, `max_gas` specified inside `#[randomness()]` will be used as the required deposit.
    struct AllowCustomMaxGasFlag has key, drop, store {
        value: bool,
    }

    /// Only used in genesis.
    fun initialize(framework: &signer, required_amount: RequiredGasDeposit, allow_custom_max_gas_flag: AllowCustomMaxGasFlag) {
        system_addresses::assert_topo_framework(framework);
        chain_status::assert_genesis();
        move_to(framework, required_amount);
        move_to(framework, allow_custom_max_gas_flag);
    }

    /// This can be called by on-chain governance to update `RequiredGasDeposit` for the next epoch.
    public fun set_for_next_epoch(framework: &signer, gas_amount: Option<u64>) {
        system_addresses::assert_topo_framework(framework);
        config_buffer::upsert(RequiredGasDeposit { gas_amount });
    }

    /// This can be called by on-chain governance to update `AllowCustomMaxGasFlag` for the next epoch.
    public fun set_allow_max_gas_flag_for_next_epoch(framework: &signer, value: bool) {
        system_addresses::assert_topo_framework(framework);
        config_buffer::upsert(AllowCustomMaxGasFlag { value } );
    }

    /// 公开安装入口检查冻结状态，防止治理脚本在等待 DKG 时提前应用缓冲配置。
    public fun on_new_epoch(framework: &signer) acquires RequiredGasDeposit, AllowCustomMaxGasFlag {
        reconfiguration_state::assert_not_in_progress();
        apply_pending_config(framework);
    }

    /// 换届流程专用入口；按已校验计划安装此前冻结的配置，全程保持冻结。
    public(friend) fun on_new_epoch_for_reconfiguration(framework: &signer) acquires RequiredGasDeposit, AllowCustomMaxGasFlag {
        apply_pending_config(framework);
    }

    /// 两种入口共用安装逻辑，仅提取本模块的两类配置，保留其他模块的缓冲项。
    fun apply_pending_config(framework: &signer) acquires RequiredGasDeposit, AllowCustomMaxGasFlag {
        system_addresses::assert_topo_framework(framework);
        if (config_buffer::does_exist<RequiredGasDeposit>()) {
            let new_config = config_buffer::extract_v2<RequiredGasDeposit>();
            if (exists<RequiredGasDeposit>(@topo_framework)) {
                *borrow_global_mut<RequiredGasDeposit>(@topo_framework) = new_config;
            } else {
                move_to(framework, new_config);
            }
        };
        if (config_buffer::does_exist<AllowCustomMaxGasFlag>()) {
            let new_config = config_buffer::extract_v2<AllowCustomMaxGasFlag>();
            if (exists<AllowCustomMaxGasFlag>(@topo_framework)) {
                *borrow_global_mut<AllowCustomMaxGasFlag>(@topo_framework) = new_config;
            } else {
                move_to(framework, new_config);
            }
        }
    }
}
