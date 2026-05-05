import { useCallback, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import {
  Alert,
  Button,
  Card,
  Col,
  Descriptions,
  Form,
  Input,
  InputNumber,
  Modal,
  Row,
  Space,
  Statistic,
  Steps,
  Table,
  Tabs,
  Tag,
  Typography,
  message,
} from 'antd';
import {
  getChainInfo,
  getGovernanceConfig,
  cleanupStaging,
  forceEndEpoch,
  getFrameworkStatus,
  mintTopo,
  setCooldownSecs,
  setEpochInterval,
  setForceExitPowerBps,
  setMinActivePower,
  setOctasPerMillionPower,
  setStakingConfig,
  setStakingRewardRate,
  setStakingRewardsConfig,
  updateGovernanceConfig,
  upgradeFramework,
} from '../services/governance';
import {
  getPowerStore,
  getPowerWritebackTask,
  configurePowerWritebackTask,
  queryPowerStoreUsers,
  runPowerWritebackOnce,
  setOperator,
  setPeriod,
  setRetention,
  stageBatch,
  stageSingle,
} from '../services/power';
import { usePolling } from '../hooks/usePolling';
import { useWebSocketEvent } from '../hooks/useWebSocket';
import AddressSelect from '../components/AddressSelect';
import AddressTag from '../components/AddressTag';
import { formatDuration, formatNumber, formatRewardRate, formatTimestamp, topoToOctas } from '../utils/format';
import './System.css';

const { Text } = Typography;

function parameterName(label: string, raw?: string): ReactNode {
  return (
    <Space direction="vertical" size={0}>
      <Text>{label}</Text>
      {raw ? <Text type="secondary" className="parameter-table-raw-name">{raw}</Text> : null}
    </Space>
  );
}

function formatBps(bps: number): string {
  return `${(Number(bps || 0) / 100).toFixed(2)}%`;
}

function formatFixedPointPercent(rate: { percent?: number; raw?: string } | undefined): string {
  if (!rate) return '0%';
  const percent = Number(rate.percent || 0);
  if (!Number.isFinite(percent) || percent === 0) return '0%';
  if (Math.abs(percent) < 0.000001) return `${percent.toExponential(2)}%`;
  return `${percent.toLocaleString(undefined, { maximumFractionDigits: 8 })}%`;
}

const DEFAULT_REWARD_RATE_DENOMINATOR = 1_000_000_000;

interface ParameterRow {
  key: string;
  parameter: ReactNode;
  current: ReactNode;
  editor: ReactNode;
  action?: ReactNode;
  actionRowSpan?: number;
}

function ParameterTable({ title, rows, scrollX = 860 }: { title?: string; rows: ParameterRow[]; scrollX?: number }) {
  return (
    <div className="parameter-table-section">
      {title ? <div className="parameter-table-title">{title}</div> : null}
      <Table<ParameterRow>
        size="small"
        rowKey="key"
        pagination={false}
        tableLayout="fixed"
        scroll={{ x: scrollX }}
        dataSource={rows}
        columns={[
          { title: '参数', dataIndex: 'parameter', width: 260 },
          { title: '当前值', dataIndex: 'current', width: 270 },
          { title: '修改值', dataIndex: 'editor', width: 300 },
          {
            title: '操作',
            dataIndex: 'action',
            width: 190,
            render: (value, row) => ({
              children: value || <Text type="secondary">-</Text>,
              props: { rowSpan: row.actionRowSpan ?? 1 },
            }),
          },
        ]}
      />
    </div>
  );
}

function percentToFraction(percent: number, denominator = DEFAULT_REWARD_RATE_DENOMINATOR): { numerator: number; denominator: number } {
  const safePercent = Number.isFinite(percent) ? Math.max(0, percent) : 0;
  return {
    numerator: Math.max(0, Math.round((safePercent / 100) * denominator)),
    denominator,
  };
}

function parseBatchUpdates(input: string): { address: string; power: number }[] {
  return input
    .split(/\n|,/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [address, power] = line.split(/\s*[:=\s]\s*/).filter(Boolean);
      return { address, power: Number(power || 0) };
    })
    .filter((item) => item.address?.startsWith('0x') && Number.isFinite(item.power));
}

export default function System() {
  const fetchChain = useCallback(() => getChainInfo(), []);
  const fetchConfig = useCallback(() => getGovernanceConfig(), []);
  const fetchPowerStore = useCallback(() => getPowerStore(), []);
  const fetchWritebackTask = useCallback(() => getPowerWritebackTask(), []);
  const { data: chain, refresh: refreshChain } = usePolling(fetchChain, 10000);
  const { data: config, refresh: refreshConfig } = usePolling(fetchConfig, 30000);
  const { data: powerStore, refresh: refreshPowerStore } = usePolling(fetchPowerStore, 0);
  const { data: writebackTask, refresh: refreshWritebackTask } = usePolling(fetchWritebackTask, 10000);

  const refreshAll = useCallback(() => {
    refreshChain();
    refreshConfig();
    refreshPowerStore();
    refreshWritebackTask();
  }, [refreshChain, refreshConfig, refreshPowerStore, refreshWritebackTask]);

  useWebSocketEvent('power_writeback_task', refreshWritebackTask);
  useWebSocketEvent('power_writeback_submitted', refreshAll);

  const [mintAddr, setMintAddr] = useState('');
  const [mintAmount, setMintAmount] = useState<number>(0);
  const [periodVal, setPeriodVal] = useState<number>(5);
  const [retentionVal, setRetentionVal] = useState<number>(9950);
  const [epochIntervalSecsVal, setEpochIntervalSecsVal] = useState<number | null>(null);
  const [octasPerMillionPowerVal, setOctasPerMillionPowerVal] = useState<number | null>(null);
  const [minActivePowerVal, setMinActivePowerVal] = useState<number | null>(null);
  const [forceExitPowerBpsVal, setForceExitPowerBpsVal] = useState<number | null>(null);
  const [minVotingThresholdVal, setMinVotingThresholdVal] = useState<number | null>(null);
  const [requiredProposerStakeVal, setRequiredProposerStakeVal] = useState<number | null>(null);
  const [votingDurationVal, setVotingDurationVal] = useState<number | null>(null);
  const [cooldownSecsVal, setCooldownSecsVal] = useState<number | null>(null);
  const [stakingMinimumStakeVal, setStakingMinimumStakeVal] = useState<number | null>(null);
  const [stakingMaximumStakeVal, setStakingMaximumStakeVal] = useState<number | null>(null);
  const [stakingLockupSecsVal, setStakingLockupSecsVal] = useState<number | null>(null);
  const [stakingVotingPowerIncreaseLimitVal, setStakingVotingPowerIncreaseLimitVal] = useState<number | null>(null);
  const [legacyRewardsRateVal, setLegacyRewardsRateVal] = useState<number | null>(null);
  const [legacyRewardsRateDenominatorVal, setLegacyRewardsRateDenominatorVal] = useState<number | null>(null);
  const [rewardsRatePercentVal, setRewardsRatePercentVal] = useState<number | null>(null);
  const [minRewardsRatePercentVal, setMinRewardsRatePercentVal] = useState<number | null>(null);
  const [rewardsRateDecreasePercentVal, setRewardsRateDecreasePercentVal] = useState<number | null>(null);
  const [operatorAddr, setOperatorAddr] = useState('');
  const [stageAddr, setStageAddr] = useState('');
  const [stagePower, setStagePower] = useState<number>(0);
  const [queryAddr, setQueryAddr] = useState('');
  const [targetPeriod, setTargetPeriod] = useState<number | null>(null);
  const [queryRows, setQueryRows] = useState<any[]>([]);
  const [batchPeriod, setBatchPeriod] = useState<number>(0);
  const [batchText, setBatchText] = useState('');
  const [batchPreview, setBatchPreview] = useState<{ address: string; power: number }[]>([]);
  const [writebackEnabled, setWritebackEnabled] = useState<boolean | null>(null);
  const [writebackInterval, setWritebackInterval] = useState<number | null>(null);
  const [writebackMaxUsers, setWritebackMaxUsers] = useState<number | null>(null);
  const [writebackMaxGas, setWritebackMaxGas] = useState<number | null>(null);
  const [writebackGasUnitPrice, setWritebackGasUnitPrice] = useState<number | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const doAction = async (name: string, fn: () => Promise<any>) => {
    setSubmitting(true);
    try {
      await fn();
      message.success(`${name}成功`);
      refreshAll();
    } catch {
      // API interceptor already reports the error.
    } finally {
      setSubmitting(false);
    }
  };

  const handleQueryUser = async () => {
    if (!queryAddr) {
      message.warning('请选择或输入用户地址');
      return;
    }
    setSubmitting(true);
    try {
      const result = await queryPowerStoreUsers({
        addresses: [queryAddr],
        target_period: targetPeriod ?? undefined,
      });
      setQueryRows(result.users || []);
    } catch {
      // API interceptor already reports the error.
    } finally {
      setSubmitting(false);
    }
  };

  const previewBatch = () => {
    const rows = parseBatchUpdates(batchText);
    setBatchPreview(rows);
    if (!rows.length) {
      message.warning('没有解析到有效的批量算力写入记录');
    }
  };

  const handleBatchStage = async () => {
    const updates = batchPreview.length ? batchPreview : parseBatchUpdates(batchText);
    if (!updates.length) {
      message.warning('没有有效的批量算力写入记录');
      return;
    }
    const target = batchPeriod || Number(powerStore?.current_period || 0) + 1;
    Modal.confirm({
      title: `确认批量写入算力到 Period ${target}?`,
      content: `共 ${updates.length} 条用户算力更新`,
      onOk: () => doAction('批量写入算力', () => stageBatch({ target_period: target, updates })),
    });
  };

  const handleSetOperator = () => {
    if (!operatorAddr) {
      message.warning('请选择或输入新的 operator 地址');
      return;
    }
    doAction('设置 Operator', () => setOperator({ operator: operatorAddr }));
  };

  const handleMintTopo = () => {
    if (!mintAddr.trim()) {
      message.warning('请输入接收地址');
      return;
    }
    doAction('铸造', () => mintTopo({ recipient: mintAddr.trim(), amount: topoToOctas(mintAmount) }));
  };

  const watchedRows = powerStore?.watched_users || [];
  const queryDataSource = queryRows.length ? queryRows : watchedRows;
  const chainCfg = config?.chain || {};
  const pwr = config?.power || {};
  const stk = config?.staking || {};
  const stakingConfig = config?.staking_config || {};
  const stakingRewardsConfig = config?.staking_rewards_config || {};
  const rewardRate = config?.reward_rate || {};
  const rewardsRateDecreaseEnabled = Boolean(config?.periodical_reward_rate_decrease_enabled);
  const gov = config?.governance || {};
  const stageTargetPeriod = Number(powerStore?.current_period || 0) + 1;
  const defaultQueryPeriod = Number(powerStore?.next_epoch_period ?? powerStore?.current_period ?? 0);
  const effectiveEpochIntervalSecs = epochIntervalSecsVal ?? Number(chainCfg.epoch_interval_secs || 0);
  const effectiveOctasPerMillionPower = octasPerMillionPowerVal ?? Number(stk.octas_per_million_power || 0);
  const effectiveMinActivePower = minActivePowerVal ?? Number(stk.min_active_power || 0);
  const effectiveForceExitPowerBps = forceExitPowerBpsVal ?? Number(stk.force_exit_power_bps || 0);
  const effectiveMinVotingThreshold = minVotingThresholdVal ?? Number(gov.min_voting_threshold || 0);
  const effectiveRequiredProposerStake = requiredProposerStakeVal ?? Number(gov.required_proposer_stake || 0);
  const effectiveVotingDuration = votingDurationVal ?? Number(gov.voting_duration_secs || 0);
  const effectiveCooldownSecs = cooldownSecsVal ?? Number(stk.cooldown_secs || 0);
  const effectiveStakingMinimumStake = stakingMinimumStakeVal ?? Number(stakingConfig.minimum_stake || 0);
  const effectiveStakingMaximumStake = stakingMaximumStakeVal ?? Number(stakingConfig.maximum_stake || 0);
  const effectiveStakingLockupSecs = stakingLockupSecsVal ?? Number(stakingConfig.recurring_lockup_duration_secs || 0);
  const effectiveStakingVotingPowerIncreaseLimit = stakingVotingPowerIncreaseLimitVal ?? Number(stakingConfig.voting_power_increase_limit || 0);
  const effectiveLegacyRewardsRate = legacyRewardsRateVal ?? Number(stakingConfig.rewards_rate || rewardRate.numerator || 0);
  const effectiveLegacyRewardsRateDenominator = legacyRewardsRateDenominatorVal ?? Number(stakingConfig.rewards_rate_denominator || rewardRate.denominator || 0);
  const effectiveRewardsRatePercent = rewardsRatePercentVal ?? Number(stakingRewardsConfig.rewards_rate?.percent || 0);
  const effectiveMinRewardsRatePercent = minRewardsRatePercentVal ?? Number(stakingRewardsConfig.min_rewards_rate?.percent || 0);
  const effectiveRewardsRateDecreasePercent = rewardsRateDecreasePercentVal ?? Number(stakingRewardsConfig.rewards_rate_decrease_rate?.percent || 0);
  const writebackSettings = writebackTask?.settings || {};
  const effectiveWritebackEnabled = writebackEnabled ?? Boolean(writebackSettings.enabled);
  const effectiveWritebackInterval = writebackInterval ?? Number(writebackSettings.interval_secs || 60);
  const effectiveWritebackMaxUsers = writebackMaxUsers ?? Number(writebackSettings.max_users_per_run || 1000);
  const effectiveWritebackMaxGas = writebackMaxGas ?? Number(writebackSettings.max_gas || 400000);
  const effectiveWritebackGasUnitPrice = writebackGasUnitPrice ?? Number(writebackSettings.gas_unit_price || 100);
  const writebackLastResult = writebackTask?.last_result || {};

  const handleSetOctasPerMillionPower = () => {
    if (effectiveOctasPerMillionPower < 0) {
      message.warning('octas_per_million_power 不能为负数');
      return;
    }
    doAction('修改 octas_per_million_power', () => setOctasPerMillionPower({ octas_per_million_power: effectiveOctasPerMillionPower }));
  };

  const handleSetMinActivePower = () => {
    if (effectiveMinActivePower <= 0) {
      message.warning('min_active_power 必须大于 0');
      return;
    }
    doAction('修改 min_active_power', () => setMinActivePower({ min_active_power: effectiveMinActivePower }));
  };

  const handleSetForceExitPowerBps = () => {
    if (effectiveForceExitPowerBps <= 0 || effectiveForceExitPowerBps > 10000) {
      message.warning('force_exit_power_bps 必须在 1 到 10000 之间');
      return;
    }
    doAction('修改 force_exit_power_bps', () => setForceExitPowerBps({ force_exit_power_bps: effectiveForceExitPowerBps }));
  };

  const handleSetCooldownSecs = () => {
    if (effectiveCooldownSecs < 0) {
      message.warning('cooldown_secs 不能为负数');
      return;
    }
    doAction('修改 cooldown_secs', () => setCooldownSecs({ cooldown_secs: effectiveCooldownSecs }));
  };

  const handleConfigureWritebackTask = () => {
    if (effectiveWritebackInterval < 5) {
      message.warning('任务间隔至少 5 秒');
      return;
    }
    if (effectiveWritebackMaxUsers <= 0) {
      message.warning('单次最大用户数必须大于 0');
      return;
    }
    doAction('保存算力上链任务', () => configurePowerWritebackTask({
      enabled: effectiveWritebackEnabled,
      interval_secs: effectiveWritebackInterval,
      max_users_per_run: effectiveWritebackMaxUsers,
      max_gas: effectiveWritebackMaxGas,
      gas_unit_price: effectiveWritebackGasUnitPrice,
    }));
  };

  const handleRunWritebackOnce = (force = false) => {
    Modal.confirm({
      title: force ? '确认强制执行算力上链?' : '确认立即执行算力上链?',
      content: force ? '强制执行会忽略本进程内的已上链 period 缓存。' : '任务会读取当前 period，并聚合上一 period 的 ContributionEvent。',
      onOk: () => doAction(force ? '强制算力上链' : '算力上链', () => runPowerWritebackOnce({ force })),
    });
  };

  const handleSetEpochInterval = () => {
    if (effectiveEpochIntervalSecs <= 0) {
      message.warning('epoch_interval_secs 必须大于 0');
      return;
    }
    doAction('修改 Epoch 秒数', () => setEpochInterval({ epoch_interval_secs: effectiveEpochIntervalSecs }));
  };

  const handleUpdateGovernanceConfig = () => {
    if (effectiveVotingDuration <= 0) {
      message.warning('voting_duration_secs 必须大于 0');
      return;
    }
    doAction('修改治理参数', () => updateGovernanceConfig({
      min_voting_threshold: effectiveMinVotingThreshold,
      required_proposer_stake: effectiveRequiredProposerStake,
      voting_duration_secs: effectiveVotingDuration,
    }));
  };

  const handleSetStakingConfig = () => {
    if (effectiveStakingMinimumStake > effectiveStakingMaximumStake || effectiveStakingMaximumStake <= 0) {
      message.warning('minimum_stake 不能大于 maximum_stake，且 maximum_stake 必须大于 0');
      return;
    }
    if (effectiveStakingLockupSecs <= 0) {
      message.warning('recurring_lockup_duration_secs 必须大于 0');
      return;
    }
    if (effectiveStakingVotingPowerIncreaseLimit <= 0 || effectiveStakingVotingPowerIncreaseLimit > 50) {
      message.warning('voting_power_increase_limit 必须在 1 到 50 之间');
      return;
    }
    doAction('修改 StakingConfig', () => setStakingConfig({
      minimum_stake: effectiveStakingMinimumStake,
      maximum_stake: effectiveStakingMaximumStake,
      recurring_lockup_duration_secs: effectiveStakingLockupSecs,
      voting_power_increase_limit: effectiveStakingVotingPowerIncreaseLimit,
    }));
  };

  const handleSetLegacyRewardRate = () => {
    if (effectiveLegacyRewardsRateDenominator <= 0) {
      message.warning('rewards_rate_denominator 必须大于 0');
      return;
    }
    if (effectiveLegacyRewardsRate > effectiveLegacyRewardsRateDenominator) {
      message.warning('rewards_rate 不能大于 rewards_rate_denominator');
      return;
    }
    doAction('修改 legacy rewards_rate', () => setStakingRewardRate({
      new_rewards_rate: effectiveLegacyRewardsRate,
      new_rewards_rate_denominator: effectiveLegacyRewardsRateDenominator,
    }));
  };

  const handleSetStakingRewardsConfig = () => {
    if (effectiveMinRewardsRatePercent > effectiveRewardsRatePercent) {
      message.warning('min_rewards_rate 不能大于 rewards_rate');
      return;
    }
    if (effectiveRewardsRatePercent > 100 || effectiveRewardsRateDecreasePercent > 100) {
      message.warning('奖励率和下降率不能超过 100%');
      return;
    }
    const rewardsRate = percentToFraction(effectiveRewardsRatePercent);
    const minRewardsRate = percentToFraction(effectiveMinRewardsRatePercent);
    const decreaseRate = percentToFraction(effectiveRewardsRateDecreasePercent);
    doAction('修改 StakingRewardsConfig', () => setStakingRewardsConfig({
      rewards_rate_numerator: rewardsRate.numerator,
      rewards_rate_denominator: rewardsRate.denominator,
      min_rewards_rate_numerator: minRewardsRate.numerator,
      min_rewards_rate_denominator: minRewardsRate.denominator,
      rewards_rate_decrease_rate_numerator: decreaseRate.numerator,
      rewards_rate_decrease_rate_denominator: decreaseRate.denominator,
    }));
  };

  const validatorAccessRows: ParameterRow[] = [
    {
      key: 'minimum_stake',
      parameter: parameterName('加入验证者最低质押', 'minimum_stake'),
      current: formatNumber(stakingConfig.minimum_stake || 0),
      editor: (
        <InputNumber
          value={stakingMinimumStakeVal ?? undefined}
          onChange={(value) => setStakingMinimumStakeVal(value ?? null)}
          min={0}
          precision={0}
          placeholder={`当前 ${formatNumber(stakingConfig.minimum_stake || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetStakingConfig}>保存质押配置</Button>,
    },
    {
      key: 'min_active_power',
      parameter: parameterName('有效算力门槛', 'min_active_power'),
      current: formatNumber(stk.min_active_power || 0),
      editor: (
        <InputNumber
          value={minActivePowerVal ?? undefined}
          onChange={(value) => setMinActivePowerVal(value ?? null)}
          min={1}
          precision={0}
          placeholder={`当前 ${formatNumber(stk.min_active_power || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetMinActivePower}>保存门槛</Button>,
    },
    {
      key: 'force_exit_power_bps',
      parameter: parameterName('强制退出阈值', 'force_exit_power_bps'),
      current: `${formatNumber(stk.force_exit_power_bps || 0)} (${formatBps(stk.force_exit_power_bps || 0)})`,
      editor: (
        <InputNumber
          value={forceExitPowerBpsVal ?? undefined}
          onChange={(value) => setForceExitPowerBpsVal(value ?? null)}
          min={1}
          max={10000}
          precision={0}
          addonAfter="bps"
          placeholder={`当前 ${formatNumber(stk.force_exit_power_bps || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetForceExitPowerBps}>保存阈值</Button>,
    },
    {
      key: 'octas_per_million_power',
      parameter: parameterName('质押到算力换算', 'octas_per_million_power'),
      current: formatNumber(stk.octas_per_million_power || 0),
      editor: (
        <InputNumber
          value={octasPerMillionPowerVal ?? undefined}
          onChange={(value) => setOctasPerMillionPowerVal(value ?? null)}
          min={0}
          precision={0}
          placeholder={`当前 ${formatNumber(stk.octas_per_million_power || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetOctasPerMillionPower}>保存换算</Button>,
    },
    {
      key: 'maximum_stake',
      parameter: parameterName('最大质押', 'maximum_stake'),
      current: formatNumber(stakingConfig.maximum_stake || 0),
      editor: (
        <InputNumber
          value={stakingMaximumStakeVal ?? undefined}
          onChange={(value) => setStakingMaximumStakeVal(value ?? null)}
          min={1}
          precision={0}
          placeholder={`当前 ${formatNumber(stakingConfig.maximum_stake || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetStakingConfig}>保存质押配置</Button>,
    },
    {
      key: 'cooldown_secs',
      parameter: parameterName('退出冷却时间', 'cooldown_secs'),
      current: `${formatNumber(stk.cooldown_secs || 0)} 秒`,
      editor: (
        <InputNumber
          value={cooldownSecsVal ?? undefined}
          onChange={(value) => setCooldownSecsVal(value ?? null)}
          min={0}
          precision={0}
          addonAfter="秒"
          placeholder={`当前 ${formatNumber(stk.cooldown_secs || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetCooldownSecs}>保存冷却</Button>,
    },
    {
      key: 'recurring_lockup_duration_secs',
      parameter: parameterName('锁仓周期', 'recurring_lockup_duration_secs'),
      current: `${formatNumber(stakingConfig.recurring_lockup_duration_secs || 0)} (${formatDuration(stakingConfig.recurring_lockup_duration_secs || 0)})`,
      editor: (
        <InputNumber
          value={stakingLockupSecsVal ?? undefined}
          onChange={(value) => setStakingLockupSecsVal(value ?? null)}
          min={1}
          precision={0}
          addonAfter="秒"
          placeholder={`当前 ${formatNumber(stakingConfig.recurring_lockup_duration_secs || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetStakingConfig}>保存质押配置</Button>,
    },
    {
      key: 'allow_validator_set_change',
      parameter: parameterName('允许验证者集合变化', 'allow_validator_set_change'),
      current: stakingConfig.allow_validator_set_change ? <Tag color="green">允许</Tag> : <Tag>不允许</Tag>,
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
  ];

  const cadenceRows: ParameterRow[] = [
    {
      key: 'epoch_interval_secs',
      parameter: parameterName('Epoch 间隔', 'epoch_interval_secs'),
      current: `${formatNumber(chainCfg.epoch_interval_secs || 0)} 秒`,
      editor: (
        <InputNumber
          value={epochIntervalSecsVal ?? undefined}
          onChange={(value) => setEpochIntervalSecsVal(value ?? null)}
          min={1}
          precision={0}
          addonAfter="秒"
          placeholder={`当前 ${formatNumber(chainCfg.epoch_interval_secs || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetEpochInterval}>保存间隔</Button>,
    },
    {
      key: 'voting_duration_secs',
      parameter: parameterName('治理投票时长', 'voting_duration_secs'),
      current: `${formatNumber(gov.voting_duration_secs || 0)} 秒`,
      editor: (
        <InputNumber
          value={votingDurationVal ?? undefined}
          onChange={(value) => setVotingDurationVal(value ?? null)}
          min={1}
          precision={0}
          addonAfter="秒"
          placeholder={`当前 ${formatNumber(gov.voting_duration_secs || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleUpdateGovernanceConfig}>保存治理参数</Button>,
      actionRowSpan: 3,
    },
    {
      key: 'min_voting_threshold',
      parameter: parameterName('最小投票阈值', 'min_voting_threshold'),
      current: formatNumber(gov.min_voting_threshold || 0),
      editor: (
        <InputNumber
          value={minVotingThresholdVal ?? undefined}
          onChange={(value) => setMinVotingThresholdVal(value ?? null)}
          min={0}
          precision={0}
          placeholder={`当前 ${formatNumber(gov.min_voting_threshold || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'required_proposer_stake',
      parameter: parameterName('提案人最低质押', 'required_proposer_stake'),
      current: formatNumber(gov.required_proposer_stake || 0),
      editor: (
        <InputNumber
          value={requiredProposerStakeVal ?? undefined}
          onChange={(value) => setRequiredProposerStakeVal(value ?? null)}
          min={0}
          precision={0}
          placeholder={`当前 ${formatNumber(gov.required_proposer_stake || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'voting_power_increase_limit',
      parameter: parameterName('投票权增长限制', 'voting_power_increase_limit'),
      current: `${formatNumber(stakingConfig.voting_power_increase_limit || 0)}%`,
      editor: (
        <InputNumber
          value={stakingVotingPowerIncreaseLimitVal ?? undefined}
          onChange={(value) => setStakingVotingPowerIncreaseLimitVal(value ?? null)}
          min={1}
          max={50}
          precision={0}
          addonAfter="%"
          placeholder={`当前 ${formatNumber(stakingConfig.voting_power_increase_limit || 0)}`}
          style={{ width: '100%' }}
        />
      ),
      action: <Button loading={submitting} onClick={handleSetStakingConfig}>保存质押配置</Button>,
    },
  ];

  const rewardRows: ParameterRow[] = [
    {
      key: 'effective_reward_rate',
      parameter: parameterName('当前生效奖励率', 'effective reward_rate'),
      current: formatRewardRate(rewardRate),
      editor: <Text type="secondary">由当前奖励模式计算</Text>,
      action: null,
    },
    {
      key: 'periodical_reward_decrease',
      parameter: parameterName('周期性奖励递减', 'periodical reward decrease'),
      current: rewardsRateDecreaseEnabled ? <Tag color="green">启用</Tag> : <Tag>未启用</Tag>,
      editor: <Text type="secondary">链上 feature 控制</Text>,
      action: null,
    },
    {
      key: 'legacy_rewards_rate',
      parameter: parameterName('Legacy 奖励分子', 'rewards_rate'),
      current: formatNumber(stakingConfig.rewards_rate || 0),
      editor: (
        <InputNumber
          value={legacyRewardsRateVal ?? undefined}
          onChange={(value) => setLegacyRewardsRateVal(value ?? null)}
          min={0}
          precision={0}
          placeholder={`当前 ${formatNumber(stakingConfig.rewards_rate || 0)}`}
          style={{ width: '100%' }}
          disabled={rewardsRateDecreaseEnabled}
        />
      ),
      action: (
        <Button loading={submitting} disabled={rewardsRateDecreaseEnabled} onClick={handleSetLegacyRewardRate}>
          保存 legacy
        </Button>
      ),
      actionRowSpan: 2,
    },
    {
      key: 'legacy_rewards_rate_denominator',
      parameter: parameterName('Legacy 奖励分母', 'rewards_rate_denominator'),
      current: formatNumber(stakingConfig.rewards_rate_denominator || 0),
      editor: (
        <InputNumber
          value={legacyRewardsRateDenominatorVal ?? undefined}
          onChange={(value) => setLegacyRewardsRateDenominatorVal(value ?? null)}
          min={1}
          precision={0}
          placeholder={`当前 ${formatNumber(stakingConfig.rewards_rate_denominator || 0)}`}
          style={{ width: '100%' }}
          disabled={rewardsRateDecreaseEnabled}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'staking_rewards_rate',
      parameter: parameterName('Staking 奖励率', 'StakingRewardsConfig.rewards_rate'),
      current: formatFixedPointPercent(stakingRewardsConfig.rewards_rate),
      editor: (
        <InputNumber
          value={rewardsRatePercentVal ?? undefined}
          onChange={(value) => setRewardsRatePercentVal(value ?? null)}
          min={0}
          max={100}
          precision={8}
          addonAfter="%"
          placeholder={`当前 ${formatFixedPointPercent(stakingRewardsConfig.rewards_rate)}`}
          style={{ width: '100%' }}
          disabled={!rewardsRateDecreaseEnabled}
        />
      ),
      action: (
        <Button loading={submitting} disabled={!rewardsRateDecreaseEnabled} onClick={handleSetStakingRewardsConfig}>
          保存 StakingRewards
        </Button>
      ),
      actionRowSpan: 3,
    },
    {
      key: 'staking_min_rewards_rate',
      parameter: parameterName('Staking 最低奖励率', 'min_rewards_rate'),
      current: formatFixedPointPercent(stakingRewardsConfig.min_rewards_rate),
      editor: (
        <InputNumber
          value={minRewardsRatePercentVal ?? undefined}
          onChange={(value) => setMinRewardsRatePercentVal(value ?? null)}
          min={0}
          max={100}
          precision={8}
          addonAfter="%"
          placeholder={`当前 ${formatFixedPointPercent(stakingRewardsConfig.min_rewards_rate)}`}
          style={{ width: '100%' }}
          disabled={!rewardsRateDecreaseEnabled}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'staking_rewards_rate_decrease_rate',
      parameter: parameterName('Staking 递减率', 'decrease_rate'),
      current: formatFixedPointPercent(stakingRewardsConfig.rewards_rate_decrease_rate),
      editor: (
        <InputNumber
          value={rewardsRateDecreasePercentVal ?? undefined}
          onChange={(value) => setRewardsRateDecreasePercentVal(value ?? null)}
          min={0}
          max={100}
          precision={8}
          addonAfter="%"
          placeholder={`当前 ${formatFixedPointPercent(stakingRewardsConfig.rewards_rate_decrease_rate)}`}
          style={{ width: '100%' }}
          disabled={!rewardsRateDecreaseEnabled}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'staking_rewards_rate_period',
      parameter: parameterName('奖励递减周期', 'reward period'),
      current: `${formatNumber(stakingRewardsConfig.rewards_rate_period_in_secs || 0)} 秒`,
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
  ];

  const powerCycleRows: ParameterRow[] = [
    {
      key: 'operator',
      parameter: parameterName('Operator', 'operator'),
      current: powerStore?.operator ? <AddressTag address={powerStore.operator} /> : '-',
      editor: <AddressSelect kind="user" value={operatorAddr || undefined} onChange={setOperatorAddr} placeholder="选择新的 operator" style={{ width: '100%' }} />,
      action: <Button loading={submitting} onClick={handleSetOperator}>保存</Button>,
    },
    {
      key: 'power_period_in_epochs',
      parameter: parameterName('算力周期长度', 'power_period_in_epochs'),
      current: `${formatNumber(powerStore?.power_period_in_epochs || 0)} Epoch`,
      editor: <InputNumber value={periodVal} onChange={(value) => setPeriodVal(value || 1)} min={1} addonAfter="Epochs" style={{ width: '100%' }} />,
      action: <Button loading={submitting} onClick={() => doAction('修改周期', () => setPeriod({ power_period_in_epochs: periodVal }))}>保存周期</Button>,
    },
    {
      key: 'retention_bps',
      parameter: parameterName('跨周期保留系数', 'retention_bps'),
      current: `${formatNumber(powerStore?.retention_bps || 0)} (${formatBps(powerStore?.retention_bps || 0)})`,
      editor: <InputNumber value={retentionVal} onChange={(value) => setRetentionVal(value || 1)} min={1} max={10000} addonAfter="bps" style={{ width: '100%' }} />,
      action: <Button loading={submitting} onClick={() => doAction('修改保留系数', () => setRetention({ retention_bps_per_period: retentionVal }))}>保存保留</Button>,
    },
    {
      key: 'decay_bps',
      parameter: parameterName('每 Period 衰减', 'decay_bps'),
      current: `${formatNumber(powerStore?.decay_bps || 0)} (${formatBps(powerStore?.decay_bps || 0)})`,
      editor: <Text type="secondary">由保留系数计算</Text>,
      action: null,
    },
    {
      key: 'current_epoch',
      parameter: parameterName('当前 Epoch', 'current_epoch'),
      current: formatNumber(powerStore?.current_epoch || 0),
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
    {
      key: 'current_period',
      parameter: parameterName('当前 Period', 'current_period'),
      current: formatNumber(powerStore?.current_period || 0),
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
    {
      key: 'period_clock',
      parameter: parameterName('Period Clock', 'period_clock'),
      current: (
        <Space wrap>
          {powerStore?.period_clock_initialized ? <Tag color="green">已初始化</Tag> : <Tag color="orange">未初始化</Tag>}
          {powerStore?.period_clock_initialized ? <Text>倒计时 {formatNumber(powerStore?.period_clock_countdown || 0)} Epoch</Text> : null}
        </Space>
      ),
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
    {
      key: 'epochs_until_next_period',
      parameter: parameterName('距离下个 Period', 'epochs_until_next_period'),
      current: powerStore?.period_clock_initialized ? `${formatNumber(powerStore?.epochs_until_next_period || 0)} Epoch` : '-',
      editor: <Text type="secondary">链上只读</Text>,
      action: null,
    },
    {
      key: 'watched_user_count',
      parameter: parameterName('已关注用户', 'watched_user_count'),
      current: formatNumber(powerStore?.watched_user_count || 0),
      editor: <Text type="secondary">本地索引</Text>,
      action: null,
    },
    {
      key: 'single_stage',
      parameter: parameterName(`单用户算力写入 P${formatNumber(stageTargetPeriod)}`, 'stage_single'),
      current: `目标 Period ${formatNumber(stageTargetPeriod)}`,
      editor: (
        <Space.Compact style={{ width: '100%' }}>
          <AddressSelect kind="user" value={stageAddr || undefined} onChange={setStageAddr} placeholder="选择用户" style={{ width: '100%' }} />
          <InputNumber value={stagePower} onChange={(value) => setStagePower(value || 0)} min={0} precision={0} placeholder="power" style={{ width: 130 }} />
        </Space.Compact>
      ),
      action: <Button loading={submitting} onClick={() => doAction('单用户算力写入', () => stageSingle({ user_address: stageAddr, power: stagePower }))}>写入</Button>,
    },
  ];

  const writebackRows: ParameterRow[] = [
    {
      key: 'running',
      parameter: parameterName('运行状态', 'task status'),
      current: (
        <Space>
          <Tag color={writebackTask?.running ? 'green' : 'default'}>{writebackTask?.running ? '运行中' : '未运行'}</Tag>
          {writebackTask?.busy ? <Tag color="blue">执行中</Tag> : null}
        </Space>
      ),
      editor: <Text type="secondary">进程状态</Text>,
      action: (
        <Space wrap>
          <Button loading={submitting} onClick={() => handleRunWritebackOnce(false)}>立即执行</Button>
          <Button danger loading={submitting} onClick={() => handleRunWritebackOnce(true)}>强制执行</Button>
        </Space>
      ),
    },
    {
      key: 'enabled',
      parameter: parameterName('任务启用', 'enabled'),
      current: writebackSettings.enabled ? <Tag color="green">已启用</Tag> : <Tag>未启用</Tag>,
      editor: (
        <Space.Compact style={{ width: '100%' }}>
          <Button
            block
            type={effectiveWritebackEnabled ? 'primary' : 'default'}
            onClick={() => setWritebackEnabled(true)}
          >
            启用
          </Button>
          <Button
            block
            type={!effectiveWritebackEnabled ? 'primary' : 'default'}
            onClick={() => setWritebackEnabled(false)}
          >
            停用
          </Button>
        </Space.Compact>
      ),
      action: <Button loading={submitting} onClick={handleConfigureWritebackTask}>保存任务配置</Button>,
      actionRowSpan: 5,
    },
    {
      key: 'interval_secs',
      parameter: parameterName('检查间隔', 'interval_secs'),
      current: `${formatNumber(writebackSettings.interval_secs || 0)} 秒`,
      editor: (
        <InputNumber
          value={effectiveWritebackInterval}
          onChange={(value) => setWritebackInterval(value ?? null)}
          min={5}
          precision={0}
          addonAfter="秒"
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'max_users_per_run',
      parameter: parameterName('单次最大用户', 'max_users_per_run'),
      current: formatNumber(writebackSettings.max_users_per_run || 0),
      editor: (
        <InputNumber
          value={effectiveWritebackMaxUsers}
          onChange={(value) => setWritebackMaxUsers(value ?? null)}
          min={1}
          precision={0}
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'max_gas',
      parameter: parameterName('最大 Gas', 'max_gas'),
      current: formatNumber(writebackSettings.max_gas || 0),
      editor: (
        <InputNumber
          value={effectiveWritebackMaxGas}
          onChange={(value) => setWritebackMaxGas(value ?? null)}
          min={1}
          precision={0}
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'gas_unit_price',
      parameter: parameterName('Gas 单价', 'gas_unit_price'),
      current: formatNumber(writebackSettings.gas_unit_price || 0),
      editor: (
        <InputNumber
          value={effectiveWritebackGasUnitPrice}
          onChange={(value) => setWritebackGasUnitPrice(value ?? null)}
          min={1}
          precision={0}
          style={{ width: '100%' }}
        />
      ),
      actionRowSpan: 0,
    },
    {
      key: 'source_period',
      parameter: parameterName('Source Period', 'source_period'),
      current: `P${formatNumber(Math.max(0, Number(powerStore?.current_period || 0) - 1))}`,
      editor: <Text type="secondary">自动计算</Text>,
      action: null,
    },
    {
      key: 'target_period',
      parameter: parameterName('Target Period', 'target_period'),
      current: `P${formatNumber(stageTargetPeriod)}`,
      editor: <Text type="secondary">自动计算</Text>,
      action: null,
    },
    {
      key: 'last_result',
      parameter: parameterName('最近结果', 'last_result'),
      current: writebackLastResult.status ? `${writebackLastResult.status}${writebackLastResult.reason ? ` / ${writebackLastResult.reason}` : ''}` : '-',
      editor: <Text type="secondary">任务输出</Text>,
      action: null,
    },
    {
      key: 'last_tx',
      parameter: parameterName('最近 TX', 'last_tx'),
      current: writebackLastResult.tx_hash ? <AddressTag address={writebackLastResult.tx_hash} /> : '-',
      editor: <Text type="secondary">任务输出</Text>,
      action: null,
    },
    {
      key: 'last_error',
      parameter: parameterName('最近错误', 'last_error'),
      current: writebackTask?.last_error || '-',
      editor: <Text type="secondary">任务输出</Text>,
      action: null,
    },
  ];

  const userColumns = useMemo(() => [
    {
      title: '用户',
      dataIndex: 'address',
      width: 220,
      render: (value: string, row: any) => (
        <Space direction="vertical" size={0}>
          <AddressTag address={value} />
          <Space size={4}>
            {row.label ? <Text type="secondary" style={{ fontSize: 12 }}>{row.label}</Text> : null}
            {row.is_validator_user ? <Tag color="blue">验证者</Tag> : null}
          </Space>
        </Space>
      ),
    },
    { title: '当前算力', dataIndex: 'committed_power', align: 'right' as const, render: (v: number) => formatNumber(v || 0) },
    { title: '目标 Period', dataIndex: 'target_period', align: 'right' as const },
    { title: '目标算力', dataIndex: 'target_power', align: 'right' as const, render: (v: number) => formatNumber(v || 0) },
    {
      title: '版本',
      render: (_: unknown, row: any) => (
        <Space direction="vertical" size={2}>
          {(row.version_rows || []).map((item: any) => (
            <Space key={item.slot} size={4}>
              <Tag color={item.selected_for_current_period ? 'green' : item.selected_for_next_epoch ? 'cyan' : 'default'}>{item.slot}</Tag>
              <Text>P{formatNumber(item.effective_period || 0)} / raw {formatNumber(item.raw_power || 0)}</Text>
              <Text type="secondary">当前 {formatNumber(item.current_decayed_power || 0)}</Text>
            </Space>
          ))}
        </Space>
      ),
    },
    {
      title: '目标计算',
      render: (_: unknown, row: any) => {
        const calc = row.target_calculation || {};
        return (
          <Space direction="vertical" size={0}>
            <Text>{calc.selected_slot || 'none'}: {formatNumber(calc.base_power || 0)} @ P{formatNumber(calc.base_period || 0)}</Text>
            <Text type="secondary">衰减 {formatNumber(calc.periods_elapsed || 0)} 次，差值 {formatNumber(calc.delta || 0)}</Text>
          </Space>
        );
      },
    },
  ], []);

  return (
    <div>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} xl={16}>
          <Card
            title="运行状态"
            size="small"
            extra={<Button size="small" onClick={refreshAll}>刷新</Button>}
          >
            <Row gutter={[16, 12]}>
              <Col xs={12} md={4}><Statistic title="Chain ID" value={chain?.chain_id || 0} /></Col>
              <Col xs={12} md={4}><Statistic title="Epoch" value={chain?.epoch || 0} /></Col>
              <Col xs={12} md={4}><Statistic title="当前 Period" value={formatNumber(powerStore?.current_period || 0)} /></Col>
              <Col xs={12} md={4}><Statistic title="下一写入" value={`P${formatNumber(stageTargetPeriod)}`} /></Col>
              <Col xs={12} md={4}><Statistic title="区块高度" value={formatNumber(chain?.block_height || 0)} /></Col>
              <Col xs={12} md={4}><Statistic title="版本" value={formatNumber(chain?.ledger_version || 0)} /></Col>
            </Row>
            <Descriptions size="small" column={{ xs: 1, md: 2 }} style={{ marginTop: 12 }}>
              <Descriptions.Item label="时间">{formatTimestamp(chain?.ledger_timestamp || '')}</Descriptions.Item>
              <Descriptions.Item label="PowerStore Operator">{powerStore?.operator ? <AddressTag address={powerStore.operator} /> : '-'}</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
        <Col xs={24} xl={8}>
          <Card title="参数摘要" size="small">
            <Descriptions size="small" column={1}>
              <Descriptions.Item label="power_period_in_epochs">{formatNumber(pwr.power_period_in_epochs || 0)}</Descriptions.Item>
              <Descriptions.Item label="retention_bps">{pwr.retention_bps || 0} ({formatBps(pwr.retention_bps || 0)})</Descriptions.Item>
              <Descriptions.Item label="epoch_interval_secs">{formatNumber(chainCfg.epoch_interval_secs || 0)}</Descriptions.Item>
              <Descriptions.Item label="octas_per_million_power">{formatNumber(stk.octas_per_million_power || 0)}</Descriptions.Item>
              <Descriptions.Item label="min_active_power">{formatNumber(stk.min_active_power || 0)}</Descriptions.Item>
              <Descriptions.Item label="force_exit_power_bps">{formatNumber(stk.force_exit_power_bps || 0)} ({formatBps(stk.force_exit_power_bps || 0)})</Descriptions.Item>
              <Descriptions.Item label="maximum_stake">{formatNumber(stakingConfig.maximum_stake || 0)}</Descriptions.Item>
              <Descriptions.Item label="reward_rate">{formatRewardRate(rewardRate)}</Descriptions.Item>
              <Descriptions.Item label="voting_duration_secs">{formatNumber(gov.voting_duration_secs || 0)}</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
      </Row>

      <Tabs
        defaultActiveKey="base"
        items={[
          {
            key: 'base',
            label: '系统操作',
            children: (
              <>
                <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
                  <Col xs={24} xl={10}>
                    <Card title="链操作" size="small">
                      <Space wrap>
                        <Button
                          type="primary"
                          danger
                          loading={submitting}
                          onClick={() => Modal.confirm({
                            title: '确认强制结束当前 Epoch?',
                            onOk: () => doAction('强制结束 Epoch', forceEndEpoch),
                          })}
                        >
                          强制结束 Epoch
                        </Button>
                        <Text type="secondary">当前 Epoch {formatNumber(chain?.epoch || 0)}</Text>
                      </Space>
                    </Card>
                  </Col>
                  <Col xs={24} xl={14}>
                    <Card title="资产操作" size="small">
                      <Form layout="vertical">
                        <Row gutter={12} align="bottom">
                          <Col xs={24} md={14}>
                            <Form.Item label="TOPO 铸造接收地址">
                              <Input value={mintAddr} onChange={(event) => setMintAddr(event.target.value)} placeholder="输入接收地址 0x..." />
                            </Form.Item>
                          </Col>
                          <Col xs={16} md={6}>
                            <Form.Item label="数量">
                              <InputNumber value={mintAmount} onChange={(value) => setMintAmount(value || 0)} addonAfter="TOPO" min={0} style={{ width: '100%' }} />
                            </Form.Item>
                          </Col>
                          <Col xs={8} md={4}>
                            <Form.Item label=" ">
                              <Button block loading={submitting} onClick={handleMintTopo}>铸造</Button>
                            </Form.Item>
                          </Col>
                        </Row>
                      </Form>
                    </Card>
                  </Col>
                </Row>

                <Row gutter={[16, 16]}>
                  <Col span={24}>
                    <Card
                      title="验证者门槛与质押约束"
                      size="small"
                      extra={<Text type="secondary">聚焦验证者加入、退出和有效算力判定</Text>}
                    >
                      <ParameterTable rows={validatorAccessRows} scrollX={980} />
                    </Card>
                  </Col>
                </Row>

                <Row gutter={[16, 16]} style={{ marginTop: 16 }}>
                  <Col span={24}>
                    <Card title="出块 / 治理节奏" size="small" extra={<Text type="secondary">控制时间节奏和治理窗口</Text>}>
                      <ParameterTable rows={cadenceRows} scrollX={980} />
                    </Card>
                  </Col>
                </Row>

                <Row gutter={[16, 16]} style={{ marginTop: 16 }}>
                  <Col span={24}>
                    <Card title="奖励参数" size="small" extra={<Text type="secondary">包含 legacy 与新奖励模式</Text>}>
                      <Alert
                        type="info"
                        showIcon
                        style={{ marginBottom: 12 }}
                        message={rewardsRateDecreaseEnabled ? '当前链使用 StakingRewardsConfig 计算奖励率' : '当前链使用 legacy rewards_rate 计算奖励率'}
                      />
                      <ParameterTable rows={rewardRows} scrollX={980} />
                    </Card>
                  </Col>
                </Row>
              </>
            ),
          },
          {
            key: 'power',
            label: 'POC 参数设置',
            children: (
              <>
                <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
                  <Col span={24}>
                    <Card title="PowerStore 周期与写入" size="small" extra={<Text type="secondary">周期配置、状态和单用户写入放在一起</Text>}>
                      <ParameterTable
                        rows={powerCycleRows}
                        scrollX={980}
                      />
                    </Card>
                  </Col>
                </Row>

                <Card title="算力上链任务" size="small" style={{ marginBottom: 16 }}>
                  <ParameterTable rows={writebackRows} scrollX={980} />
                </Card>

                <Card title="批量算力写入" size="small">
                  <Form layout="vertical">
                    <Row gutter={[16, 16]}>
                      <Col xs={24} xl={16}>
                        <Form.Item label="算力写入记录">
                          <Input.TextArea
                            value={batchText}
                            onChange={(event) => setBatchText(event.target.value)}
                            rows={5}
                            placeholder={'每行一条：0xabc... 1000\n也支持：0xabc...:1000 或 0xabc...=1000'}
                          />
                        </Form.Item>
                      </Col>
                      <Col xs={24} xl={8}>
                        <Form.Item label="目标 Period">
                          <InputNumber
                            value={batchPeriod || undefined}
                            onChange={(value) => setBatchPeriod(value || 0)}
                            min={0}
                            precision={0}
                            placeholder={`默认 ${stageTargetPeriod}`}
                            style={{ width: '100%' }}
                          />
                        </Form.Item>
                        <Space wrap>
                          <Button onClick={previewBatch}>预览</Button>
                          <Button type="primary" loading={submitting} onClick={handleBatchStage}>提交批量写入</Button>
                          <Text type="secondary">目标应为当前 Period + 1</Text>
                        </Space>
                      </Col>
                    </Row>
                  </Form>
                  {batchPreview.length > 0 ? (
                    <Table
                      size="small"
                      rowKey={(row) => row.address}
                      dataSource={batchPreview}
                      pagination={{ pageSize: 5 }}
                      columns={[
                        { title: '地址', dataIndex: 'address', render: (value: string) => <AddressTag address={value} /> },
                        { title: 'Power', dataIndex: 'power', align: 'right' as const, render: (value: number) => formatNumber(value || 0) },
                      ]}
                    />
                  ) : null}
                </Card>
              </>
            ),
          },
          {
            key: 'users',
            label: '用户数据',
            children: (
              <>
                <Card title="PowerStore 用户查询" size="small" style={{ marginBottom: 16 }}>
                  <Row gutter={12} align="bottom">
                    <Col xs={24} md={12}>
                      <Form.Item label="用户地址" style={{ marginBottom: 0 }}>
                        <AddressSelect kind="user" value={queryAddr || undefined} onChange={setQueryAddr} placeholder="选择用户" style={{ width: '100%' }} />
                      </Form.Item>
                    </Col>
                    <Col xs={16} md={8}>
                      <Form.Item label="目标 Period" style={{ marginBottom: 0 }}>
                        <InputNumber value={targetPeriod ?? undefined} onChange={(value) => setTargetPeriod(value ?? null)} min={0} precision={0} placeholder={`默认 P${formatNumber(defaultQueryPeriod)}`} style={{ width: '100%' }} />
                      </Form.Item>
                    </Col>
                    <Col xs={8} md={4}>
                      <Button block loading={submitting} onClick={handleQueryUser}>查询</Button>
                    </Col>
                  </Row>
                </Card>
                <Card title="PowerStore 用户视图" size="small">
                  <Table
                    dataSource={queryDataSource}
                    columns={userColumns}
                    rowKey="address"
                    size="small"
                    pagination={{ pageSize: 8 }}
                    scroll={{ x: 1060 }}
                  />
                </Card>
              </>
            ),
          },
          {
            key: 'upgrade',
            label: '框架升级',
            children: <FrameworkUpgradeTab />,
          },
        ]}
      />
    </div>
  );
}


interface UpgradeProgress {
  step: string;
  status: string;
  current?: number;
  total?: number;
  total_chunks?: number;
  total_bytes?: number;
  modules?: number;
  tx_hash?: string;
  upgrade_number?: number;
  old_upgrade_number?: number;
  staging_cleaned?: boolean;
  error?: string;
}

function FrameworkUpgradeTab() {
  const fetchStatus = useCallback(() => getFrameworkStatus(), []);
  const { data: fwStatus, refresh: refreshStatus } = usePolling(fetchStatus, 15000);
  const [upgrading, setUpgrading] = useState(false);
  const [progress, setProgress] = useState<UpgradeProgress[]>([]);
  const [cleaningUp, setCleaningUp] = useState(false);

  useWebSocketEvent('framework_upgrade_progress', (data) => {
    const p = data as unknown as UpgradeProgress;
    setProgress((prev) => [...prev, p]);
    if (p.step === 'verify' || (p.step === 'error' && p.status === 'failed')) {
      setUpgrading(false);
      refreshStatus();
    }
  });

  const handleUpgrade = () => {
    Modal.confirm({
      title: '确认升级 Framework?',
      content: '将编译并部署 aptos-framework 到链上，过程约需 5-10 分钟。',
      okText: '开始升级',
      okType: 'danger',
      onOk: async () => {
        setProgress([]);
        setUpgrading(true);
        try {
          await upgradeFramework();
        } catch {
          setUpgrading(false);
        }
      },
    });
  };

  const handleCleanup = async () => {
    setCleaningUp(true);
    try {
      await cleanupStaging();
      message.success('StagingArea 已清理');
      refreshStatus();
    } catch {
      // interceptor handles error
    } finally {
      setCleaningUp(false);
    }
  };

  const lastError = [...progress].reverse().find((p: UpgradeProgress) => p.status === 'failed');
  const lastSubmit = [...progress].reverse().find((p: UpgradeProgress) => p.step === 'submit');
  const verifyResult = progress.find((p) => p.step === 'verify');

  const currentStep = (() => {
    if (!progress.length) return -1;
    const last = progress[progress.length - 1];
    if (last.step === 'preflight') return 0;
    if (last.step === 'compile') return 1;
    if (last.step === 'chunk') return 2;
    if (last.step === 'submit') return 3;
    if (last.step === 'verify') return 4;
    if (last.step === 'error') {
      const prev = progress.length > 1 ? progress[progress.length - 2] : null;
      if (!prev) return 0;
      if (prev.step === 'preflight') return 0;
      if (prev.step === 'compile') return 1;
      if (prev.step === 'chunk') return 2;
      if (prev.step === 'submit') return 3;
      return 0;
    }
    return -1;
  })();

  const stepStatus = lastError ? 'error' : (verifyResult ? 'finish' : 'process');

  return (
    <>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col span={24}>
          <Alert
            type="info"
            showIcon
            message="框架升级流程"
            description={
              <div>
                <p style={{ margin: '4px 0' }}>升级 0x1 AptosFramework 合约。适用于修改了 <code>aptos-move/framework/aptos-framework/sources/</code> 下的 Move 源码后，需要将改动部署到链上的场景。</p>
                <ol style={{ margin: '8px 0', paddingLeft: 20 }}>
                  <li><b>预检查</b> — 确认链上无残留的 StagingArea</li>
                  <li><b>编译</b> — 编译整个 aptos-framework 包，生成 metadata 和 module 字节码</li>
                  <li><b>分块</b> — 将包按 60KB 拆分为多个 chunk（单笔交易大小限制）</li>
                  <li><b>逐块提交</b> — 通过 <code>0x7::large_packages</code> 分块 stage 到链上，最后一块触发 publish</li>
                  <li><b>验证</b> — 确认 StagingArea 已清理、upgrade_number 递增</li>
                </ol>
                <p style={{ margin: '4px 0', color: '#faad14' }}>升级过程约需 5-10 分钟，期间请勿关闭页面。如中途失败，可点击"清理 StagingArea"后重试。</p>
              </div>
            }
          />
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} md={12}>
          <Card title="当前状态" size="small">
            <Descriptions column={1} size="small">
              <Descriptions.Item label="upgrade_number">
                {fwStatus?.upgrade_number ?? '-'}
              </Descriptions.Item>
              <Descriptions.Item label="StagingArea">
                {fwStatus?.has_staging_area
                  ? <Tag color="warning">有残留</Tag>
                  : <Tag color="success">无残留</Tag>}
              </Descriptions.Item>
              <Descriptions.Item label="Framework 源码">
                {fwStatus?.framework_source_exists
                  ? <Tag color="success">存在</Tag>
                  : <Tag color="error">不存在</Tag>}
              </Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
        <Col xs={24} md={12}>
          <Card title="升级操作" size="small">
            <Space direction="vertical" style={{ width: '100%' }}>
              <Button
                type="primary"
                danger
                block
                loading={upgrading}
                disabled={!fwStatus?.framework_source_exists}
                onClick={handleUpgrade}
              >
                一键升级 Framework
              </Button>
              {fwStatus?.has_staging_area && (
                <Button block loading={cleaningUp} onClick={handleCleanup}>
                  清理 StagingArea
                </Button>
              )}
            </Space>
          </Card>
        </Col>
      </Row>

      {progress.length > 0 && (
        <Card title="升级进度" size="small">
          <Steps
            current={currentStep}
            status={stepStatus}
            direction="vertical"
            size="small"
            items={[
              {
                title: '预检查',
                description: progress.find((p) => p.step === 'preflight')
                  ? `通过 (当前 upgrade_number: ${progress.find((p) => p.step === 'preflight')?.upgrade_number})`
                  : undefined,
              },
              {
                title: '编译',
                description: progress.find((p) => p.step === 'compile')
                  ? `完成 (${((progress.find((p) => p.step === 'compile')?.total_bytes || 0) / 1024).toFixed(0)} KB, ${progress.find((p) => p.step === 'compile')?.modules} modules)`
                  : undefined,
              },
              {
                title: '分块',
                description: progress.find((p) => p.step === 'chunk')
                  ? `完成 (${progress.find((p) => p.step === 'chunk')?.total_chunks} chunks)`
                  : undefined,
              },
              {
                title: '逐块提交',
                description: lastSubmit
                  ? `${lastSubmit.current}/${lastSubmit.total} (tx: ${lastSubmit.tx_hash?.slice(0, 10)}...)`
                  : (upgrading && currentStep >= 3 ? '提交中...' : undefined),
              },
              {
                title: '验证',
                description: verifyResult
                  ? `upgrade_number: ${verifyResult.old_upgrade_number} → ${verifyResult.upgrade_number}`
                  : undefined,
              },
            ]}
          />
          {lastError && (
            <Alert
              type="error"
              showIcon
              style={{ marginTop: 12 }}
              message="升级失败"
              description={lastError.error}
            />
          )}
        </Card>
      )}
    </>
  );
}
