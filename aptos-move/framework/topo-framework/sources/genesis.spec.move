spec topo_framework::genesis {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: All the core resources and modules should be created during genesis and owned by the Aptos framework
    /// account.
    /// Criticality: Critical
    /// Implementation: Resources created during genesis initialization: GovernanceResponsbility, ConsensusConfig,
    /// ExecutionConfig, Version, SetVersionCapability, ValidatorSet, ValidatorPerformance, StakingConfig,
    /// StorageGasConfig, StorageGas, GasScheduleV2, AggregatorFactory, SupplyConfig, ChainId, Configuration,
    /// BlockResource, StateStorageUsage, CurrentTimeMicroseconds. If some of the resources were to be owned by a
    /// malicious account, it could lead to the compromise of the chain, as these are core resources. It should be
    /// formally verified by a post condition to ensure that all the critical resources are owned by the Aptos framework.
    /// Enforcement: Formally verified via [high-level-req-1](initialize).
    ///
    /// No.: 2
    /// Requirement: Addresses ranging from 0x0 - 0xa should be reserved for the framework and part of aptos governance.
    /// Criticality: Critical
    /// Implementation: The function genesis::initialize calls account::create_framework_reserved_account for addresses
    /// 0x0, 0x2, 0x3, 0x4, ..., 0xa which creates an account and authentication_key for them. This should be formally
    /// verified by ensuring that at the beginning of the genesis::initialize function no Account resource exists for
    /// the reserved addresses, and at the end of the function, an Account resource exists.
    /// Enforcement: Formally verified via [high-level-req-2](initialize).
    ///
    /// No.: 3
    /// Requirement: The Aptos coin should be initialized during genesis and only the Aptos framework account should own
    /// the mint and burn capabilities for the APT token.
    /// Criticality: Critical
    /// Implementation: The stake and transaction_fee modules store the mint and
    /// burn capabilities under the Aptos framework account.
    /// Enforcement: Formally verified via [high-level-req-3](initialize_topo_coin).
    ///
    /// No.: 4
    /// Requirement: An initial set of validators should exist before the end of genesis.
    /// Criticality: Low
    /// Implementation: To ensure that there will be a set of validators available to validate the genesis block, the
    /// length of the ValidatorSet.active_validators vector should be > 0.
    /// Enforcement: Formally verified via [high-level-req-4](set_genesis_end).
    ///
    /// No.: 5
    /// Requirement: The end of genesis should be marked on chain.
    /// Criticality: Low
    /// Implementation: The end of genesis is marked, on chain, via the chain_status::GenesisEndMarker resource. The
    /// ownership of this resource marks the operating state of the chain.
    /// Enforcement: Formally verified via [high-level-req-5](set_genesis_end).
    /// </high-level-req>
    spec module {
        pragma verify = true;
    }

    spec initialize {
        pragma opaque;
        pragma aborts_if_is_partial;
        include InitalizeRequires;

        // property 2: Addresses ranging from 0x0 - 0xa should be reserved for the framework and part of aptos governance.
        // 0x1's pre and post conditions are written in requires schema and the following group of ensures.
        /// [high-level-req-2]
        aborts_if exists<account::Account>(@0x0);
        aborts_if exists<account::Account>(@0x2);
        aborts_if exists<account::Account>(@0x3);
        aborts_if exists<account::Account>(@0x4);
        aborts_if exists<account::Account>(@0x5);
        aborts_if exists<account::Account>(@0x6);
        aborts_if exists<account::Account>(@0x7);
        aborts_if exists<account::Account>(@0x8);
        aborts_if exists<account::Account>(@0x9);
        aborts_if exists<account::Account>(@0xa);
        ensures exists<account::Account>(@0x0);
        ensures exists<account::Account>(@0x2);
        ensures exists<account::Account>(@0x3);
        ensures exists<account::Account>(@0x4);
        ensures exists<account::Account>(@0x5);
        ensures exists<account::Account>(@0x6);
        ensures exists<account::Account>(@0x7);
        ensures exists<account::Account>(@0x8);
        ensures exists<account::Account>(@0x9);
        ensures exists<account::Account>(@0xa);

        // property 1: All the core resources and modules should be created during genesis and owned by the Aptos framework account.
        /// [high-level-req-1]
        ensures exists<topo_governance::GovernanceResponsbility>(@topo_framework);
        ensures exists<consensus_config::ConsensusConfig>(@topo_framework);
        ensures exists<execution_config::ExecutionConfig>(@topo_framework);
        ensures exists<version::Version>(@topo_framework);
        ensures exists<stake::ValidatorSet>(@topo_framework);
        ensures exists<stake::ValidatorPerformance>(@topo_framework);
        ensures exists<storage_gas::StorageGasConfig>(@topo_framework);
        ensures exists<storage_gas::StorageGas>(@topo_framework);
        ensures exists<gas_schedule::GasScheduleV2>(@topo_framework);
        ensures exists<aggregator_factory::AggregatorFactory>(@topo_framework);
        ensures exists<coin::SupplyConfig>(@topo_framework);
        ensures exists<chain_id::ChainId>(@topo_framework);
        ensures exists<reconfiguration::Configuration>(@topo_framework);
        ensures exists<block::BlockResource>(@topo_framework);
        ensures exists<state_storage::StateStorageUsage>(@topo_framework);
        ensures exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        ensures exists<account::Account>(@topo_framework);
        ensures exists<version::SetVersionCapability>(@topo_framework);
        ensures exists<staking_config::StakingConfig>(@topo_framework);
        ensures !exists<stake::TopoCoinCapabilities>(@topo_framework);
    }

    spec initialize_topo_coin {
        pragma opaque;
        // property 3: The Aptos coin should be initialized during genesis and only the Aptos framework account should
        // own the mint and burn capabilities for the APT token.
        /// [high-level-req-3]
        requires !exists<stake::TopoCoinCapabilities>(@topo_framework);
        ensures exists<stake::TopoCoinCapabilities>(@topo_framework);
    }

    spec initialize_validator {
    }

    spec create_accounts {
        pragma opaque;
    }

    spec create_employee_validators {
        pragma opaque;
    }

    spec create_initialize_validators_with_commission {
        pragma verify_duration_estimate = 120;

        // 原生验证者创建流程要求尚未准备 PoC，满足原生 Epoch 安装入口的前置条件。
        requires !exists<topo_framework::poc_accounting::AccountingState>(@topo_framework);
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include CompareTimeRequires;
        include topo_coin::ExistsTopoCoin;
    }

    spec create_initialize_poc_validators {
        pragma aborts_if_is_partial;
        // 两种验证者创建分支之前均已执行共同的原生资源初始化。
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include staking_config::StakingRewardsConfigRequirement;
        include CompareTimeRequires;
        include topo_coin::ExistsTopoCoin;
        // 直接 PoC 创世从链 Epoch 0 开始，要求尚未准备 PoC，也没有缓存计划。
        requires exists<reconfiguration::Configuration>(@topo_framework);
        requires global<reconfiguration::Configuration>(@topo_framework).epoch == 0;
        requires !exists<topo_framework::poc_accounting::AccountingState>(@topo_framework);
        requires !exists<topo_framework::poc_power_store::PowerStore>(@topo_framework);
        requires !exists<topo_framework::poc_power_store::PeriodClock>(@topo_framework);
        requires !exists<stake::InstalledRewardContext>(@topo_framework);
        requires !exists<stake::EpochPlan>(@topo_framework);
        requires !exists<stake::PrecomputedValidatorSet>(@topo_framework);
        aborts_if !chain_status::is_genesis();
        aborts_if std::signer::address_of(framework) != @topo_framework;
        aborts_if initial_raw_power == 0;
        ensures topo_framework::poc_accounting::current_epoch() == 1;
        ensures stake::spec_poc_enabled();
        // 可治理的初始配置由创世入口统一选择，不由清单重复覆盖。
        ensures exists<topo_framework::poc_power_store::PowerStore>(@topo_framework);
        ensures exists<topo_framework::poc_power_store::PeriodClock>(@topo_framework);
        ensures global<topo_framework::poc_power_store::PowerStore>(@topo_framework).operator == @topo_framework;
        ensures global<topo_framework::poc_power_store::PeriodClock>(@topo_framework).power_period_in_epochs
            == POC_POWER_PERIOD_IN_EPOCHS;
        ensures exists<stake::TransactionFeeConfig>(@topo_framework);
        ensures global<stake::TransactionFeeConfig>(@topo_framework).max_fee_octa_allowed_per_epoch_per_pool == 0;
        ensures global<stake::InstalledRewardContext>(@topo_framework).context.epoch == 1;
        // 委员会与账本已安装 Epoch 1，链配置随后由既有创世事件步骤推进。
        ensures reconfiguration::current_epoch() == 0;
    }

    spec create_initialize_validators {
        pragma verify_duration_estimate = 120;

        requires !exists<topo_framework::poc_accounting::AccountingState>(@topo_framework);
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include CompareTimeRequires;
        include topo_coin::ExistsTopoCoin;
    }

    // 单池初始化后，后续循环和 Epoch 安装所需的验证者集合与代币资源仍须存在。
    spec create_initialize_validator {
        pragma opaque;
        include stake::ResourceRequirement;
        include topo_coin::ExistsTopoCoin;
        ensures exists<stake::ValidatorSet>(@topo_framework);
        ensures exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
    }

    spec initialize_for_verification {
        // We construct `initialize_for_verification` which is a "#[verify_only]" function that
        // simulates the genesis encoding process in `vm-genesis` (written in Rust).
        include InitalizeRequires;
    }

    spec set_genesis_end {
        pragma delegate_invariants_to_caller;
        // property 4: An initial set of validators should exist before the end of genesis.
        /// [high-level-req-4]
        requires len(global<stake::ValidatorSet>(@topo_framework).active_validators) >= 1;
        // property 5: The end of genesis should be marked on chain.
        /// [high-level-req-5]
        let addr = std::signer::address_of(topo_framework);
        aborts_if addr != @topo_framework;
        aborts_if exists<chain_status::GenesisEndMarker>(@topo_framework);
        ensures global<chain_status::GenesisEndMarker>(@topo_framework) == chain_status::GenesisEndMarker {};
    }

    spec schema InitalizeRequires {
        execution_config: vector<u8>;
        requires !exists<account::Account>(@topo_framework);
        requires !exists<topo_framework::poc_accounting::AccountingState>(@topo_framework);
        requires chain_status::is_operating();
        requires len(execution_config) > 0;
        requires exists<staking_config::StakingRewardsConfig>(@topo_framework);
        requires exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
        include CompareTimeRequires;
    }

    spec schema CompareTimeRequires {
        let staking_rewards_config = global<staking_config::StakingRewardsConfig>(@topo_framework);
        requires staking_rewards_config.last_rewards_rate_period_start_in_secs <= timestamp::spec_now_seconds();
    }
}
