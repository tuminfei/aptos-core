// 验证公开配置入口在冻结期间拒绝设置、安装和初始化，解除冻结后可恢复操作。
#[test_only]
module topo_framework::poc_freeze_tests {
    use std::option;
    use topo_framework::config_buffer;
    use topo_framework::randomness_api_v0_config;
    use topo_framework::randomness_config;
    use topo_framework::reconfiguration_state;
    use topo_framework::staking_config;
    use topo_framework::timestamp;

    fun start_freeze(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        reconfiguration_state::initialize(framework);
        config_buffer::initialize(framework);
        reconfiguration_state::start_for_test();
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = topo_framework::reconfiguration_state)]
    fun poc_public_config_install_is_frozen(framework: signer) {
        timestamp::set_time_has_started_for_testing(&framework);
        reconfiguration_state::initialize(&framework);
        config_buffer::initialize(&framework);
        randomness_api_v0_config::set_for_next_epoch(&framework, option::some(123));
        reconfiguration_state::start_for_test();
        randomness_api_v0_config::on_new_epoch(&framework);
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = topo_framework::reconfiguration_state)]
    fun poc_buffered_config_set_is_frozen(framework: signer) {
        start_freeze(&framework);
        randomness_api_v0_config::set_for_next_epoch(&framework, option::some(123));
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = topo_framework::reconfiguration_state)]
    fun poc_config_initialize_is_frozen(framework: signer) {
        start_freeze(&framework);
        randomness_config::initialize(&framework, randomness_config::new_off());
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = topo_framework::reconfiguration_state)]
    fun poc_native_config_set_is_frozen(framework: signer) {
        start_freeze(&framework);
        staking_config::update_required_stake(&framework, 1, 100);
    }

    #[test(framework = @0x1)]
    fun poc_config_set_resumes_after_finish(framework: signer) {
        start_freeze(&framework);
        reconfiguration_state::finish_for_test();
        randomness_api_v0_config::set_for_next_epoch(&framework, option::some(123));
        randomness_api_v0_config::on_new_epoch(&framework);
    }
}
