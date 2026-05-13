import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { Row, Col, Card, Statistic, Button, InputNumber, Space, Modal, message, Tag, Descriptions, Table, Tabs, Tooltip, Typography } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getUser, getUserContributionEvents } from '../../services/user';
import { getUserPowerPeriodHistory, getUserSnapshotHistory } from '../../services/history';
import { mintTopo } from '../../services/governance';
import { stageSingle } from '../../services/power';
import { deposit, delegate, undelegate, withdraw } from '../../services/staking';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressTag from '../../components/AddressTag';
import AddressSelect from '../../components/AddressSelect';
import HistoryWindowControl from '../../components/HistoryWindowControl';
import { createScaledValueAxis } from '../../utils/chart';
import { addressKey, formatCompactNumber, formatDuration, formatNumber, formatRewardAmount, formatRewardRate, formatTimestamp, formatTopo, topoToOctas } from '../../utils/format';

const { Text } = Typography;

function DetailPanel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div
      style={{
        height: '100%',
        border: '1px solid #f0f0f0',
        borderRadius: 8,
        padding: 12,
        background: '#fafafa',
      }}
    >
      <div style={{ marginBottom: 8, fontWeight: 600, color: '#262626' }}>{title}</div>
      {children}
    </div>
  );
}

export default function UserDetail() {
  const { address } = useParams<{ address: string }>();
  const [snapshotLimit, setSnapshotLimit] = useState(50);
  const [snapshotOffset, setSnapshotOffset] = useState(0);
  const [powerPeriodLimit, setPowerPeriodLimit] = useState(50);
  const [powerPeriodOffset, setPowerPeriodOffset] = useState(0);
  const [contributionPage, setContributionPage] = useState(1);
  const [contributionPageSize, setContributionPageSize] = useState(10);
  const fetchUser = useCallback(() => getUser(address!), [address]);
  const fetchSnapshotHistory = useCallback(() => getUserSnapshotHistory(address!, snapshotLimit, snapshotOffset), [address, snapshotLimit, snapshotOffset]);
  const fetchPowerPeriodHistory = useCallback(() => getUserPowerPeriodHistory(address!, powerPeriodLimit, powerPeriodOffset), [address, powerPeriodLimit, powerPeriodOffset]);
  const fetchContributionHistory = useCallback(() => getUserContributionEvents(address!, 50, 0), [address]);
  const { data, loading, refresh } = usePolling(fetchUser, 0, [address]);
  const { data: snapshotData, refresh: refreshSnapshotHistory } = usePolling(fetchSnapshotHistory, 0, [address, snapshotLimit, snapshotOffset]);
  const { data: powerPeriodData, refresh: refreshPowerPeriodHistory } = usePolling(fetchPowerPeriodHistory, 0, [address, powerPeriodLimit, powerPeriodOffset]);
  const { data: contributionData, refresh: refreshContributionHistory } = usePolling(fetchContributionHistory, 0, [address]);

  const [mintAmount, setMintAmount] = useState<number>(0);
  const [powerVal, setPowerVal] = useState<number>(0);
  const [depositAmount, setDepositAmount] = useState<number>(0);
  const [delegateTo, setDelegateTo] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const u = data || {};
  const balance = u.balance || {};
  const power = u.power || {};
  const powerStore = u.power_store || {};
  const staking = u.staking || {};
  const rewards = u.rewards || {};
  const rewardRate = rewards.reward_rate || {};
  const snapshots = snapshotData?.history || [];
  const powerPeriods = powerPeriodData?.history || [];
  const cumulativeRewards = snapshotData?.cumulative_rewards || {};
  const contributionEvents = contributionData?.events || [];
  const pagedContributionEvents = useMemo(() => {
    const start = (contributionPage - 1) * contributionPageSize;
    return contributionEvents.slice(start, start + contributionPageSize);
  }, [contributionEvents, contributionPage, contributionPageSize]);
  const formatBps = (bps: number) => `${(Number(bps || 0) / 100).toFixed(2)}%`;
  const currentCalculation = powerStore.current_calculation || {};
  const nextEpochCalculation = powerStore.next_epoch_calculation || {};
  const versionRows = (powerStore.version_rows || []).map((row: any) => ({ key: row.slot, ...row }));
  const cooldownUntil = Number(staking.cooldown_until || 0);
  const cooldownRemaining = Number(staking.cooldown_remaining_secs || 0);
  const cooldownReason = staking.cooldown_reason || '该账户已解除委托并处于链上冷却期。';
  const cooldownSource = staking.cooldown_source;
  const currentBasePower = Number(currentCalculation.base_power || 0);
  const currentRawPower = currentBasePower;
  const calcRows = [
    { key: 'current', label: '当前 period', ...currentCalculation },
    { key: 'next', label: '下一 epoch period', ...nextEpochCalculation },
  ];
  const powerPeriodInEpochs = Number(powerStore.power_period_in_epochs || 0);
  const rawPowerEventsByPeriod = new Map<number, {
    period: number;
    rawPower: number;
    sourceSlot: string;
    sampledAt?: string;
    epoch?: number;
  }>();
  const effectivePowerByPeriod = new Map<number, number>();
  const setRawPowerPoint = (
    period: number,
    rawPower: number,
    sourceSlot: string,
    options: {
      sampledAt?: string;
      epoch?: number;
    } = {},
  ) => {
    if (!Number.isFinite(period) || !Number.isFinite(rawPower) || period <= 0) {
      return;
    }
    const existing = rawPowerEventsByPeriod.get(period);
    if (!existing || options.sampledAt || (sourceSlot === 'current' && !existing.sampledAt)) {
      rawPowerEventsByPeriod.set(period, {
        period,
        rawPower,
        sourceSlot,
        sampledAt: options.sampledAt,
        epoch: options.epoch,
      });
    }
  };
  powerPeriods.forEach((row: any) => {
    const period = Number(row.period);
    const rawPower = Number(row.raw_power);
    if (!Number.isFinite(period) || !Number.isFinite(rawPower)) {
      return;
    }
    setRawPowerPoint(period, rawPower, row.source_slot || 'history', {
      sampledAt: row.sampled_at,
      epoch: Number(row.epoch || 0),
    });
  });
  versionRows.forEach((row: any) => {
    if (!row.present) {
      return;
    }
    setRawPowerPoint(
      Number(row.effective_period),
      Number(row.raw_power),
      row.selected_for_current_period ? 'current' : row.slot || 'slot',
    );
  });
  snapshots.forEach((row: any) => {
    const epoch = Number(row.epoch || 0);
    const snapshotPeriod = Number(row.current_period);
    if (Number.isFinite(snapshotPeriod) && snapshotPeriod > 0) {
      effectivePowerByPeriod.set(snapshotPeriod, Number(row.effective_power || 0));
      return;
    }
    if (epoch <= 0 || powerPeriodInEpochs <= 0) {
      return;
    }
    const period = Math.floor((epoch - 1) / powerPeriodInEpochs);
    effectivePowerByPeriod.set(period, Number(row.effective_power || 0));
  });
  const currentPeriod = Number(powerStore.current_period || 0);
  if (Number.isFinite(currentPeriod) && currentPeriod >= 0) {
    effectivePowerByPeriod.set(currentPeriod, Number(power.effective_power || 0));
  }
  const rawPowerEvents = Array.from(rawPowerEventsByPeriod.values()).sort((a, b) => a.period - b.period);
  const effectivePowerPeriods = Array.from(effectivePowerByPeriod.keys()).sort((a, b) => a - b);
  const powerTrendPeriods = effectivePowerPeriods.length > 0
    ? effectivePowerPeriods
    : rawPowerEvents.map((row) => row.period);
  const powerTrendRows = powerTrendPeriods.map((period) => {
    const rawPoint = rawPowerEventsByPeriod.get(period);
    return {
      period,
      rawPower: rawPoint?.rawPower ?? null,
      sourceSlot: rawPoint?.sourceSlot,
      sampledAt: rawPoint?.sampledAt,
      epoch: rawPoint?.epoch,
      effectivePower: effectivePowerByPeriod.get(period) ?? null,
    };
  });
  const rawPowerPeriodSeries = powerTrendRows.map((row) => row.rawPower);
  const effectivePowerSeries = powerTrendRows.map((row) => row.effectivePower);
  const powerTrendValues = [...rawPowerPeriodSeries, ...effectivePowerSeries].filter((value): value is number => value !== null && Number.isFinite(value));
  const powerTrendYAxis = {
    ...createScaledValueAxis({
      values: powerTrendValues,
      formatter: formatCompactNumber,
    }),
    min: 0,
  };
  const powerTrendChartOption = {
    grid: { left: 56, right: 32, top: 32, bottom: 32, containLabel: true },
    tooltip: {
      trigger: 'axis' as const,
      valueFormatter: (value: number | string) => typeof value === 'number' ? formatNumber(value) : value,
    },
    legend: { top: 0 },
    xAxis: { type: 'category' as const, data: powerTrendRows.map((row) => `P${row.period}`) },
    yAxis: powerTrendYAxis,
    series: [
      {
        name: '原始算力',
        type: 'bar',
        barMaxWidth: 36,
        data: rawPowerPeriodSeries,
      },
      {
        name: '有效算力',
        type: 'line',
        smooth: true,
        data: effectivePowerSeries,
      },
    ],
  };
  const snapshotLabels = snapshots.map((h: any) => {
    const date = new Date(h.sampled_at);
    return Number.isNaN(date.getTime()) ? h.sampled_at : date.toLocaleTimeString();
  });
  const depositSeries = snapshots.map((h: any) => Number(h.deposit_octas || 0) / 1e8);
  const balanceSeries = snapshots.map((h: any) => Number(h.balance_octas || 0) / 1e8);
  const estimatedRewardSeries = snapshots.map((h: any) => Number(h.estimated_epoch_total_octas || 0) / 1e8);
  const snapshotAssetChartOption = {
    tooltip: { trigger: 'axis' as const },
    legend: { top: 0 },
    grid: { left: 56, right: 64, top: 44, bottom: 32, containLabel: true },
    xAxis: { type: 'category' as const, data: snapshotLabels },
    yAxis: [
      createScaledValueAxis({
        name: '保证金',
        values: depositSeries,
        formatter: formatCompactNumber,
        position: 'left',
      }),
      createScaledValueAxis({
        name: '余额',
        values: balanceSeries,
        formatter: formatCompactNumber,
        position: 'right',
      }),
    ],
    series: [
      {
        name: '保证金',
        type: 'line',
        smooth: true,
        data: depositSeries,
      },
      {
        name: '余额',
        type: 'line',
        yAxisIndex: 1,
        smooth: true,
        data: balanceSeries,
      },
    ],
  };
  const snapshotRewardChartOption = {
    tooltip: { trigger: 'axis' as const },
    legend: { top: 0 },
    grid: { left: 56, right: 32, top: 44, bottom: 32, containLabel: true },
    xAxis: { type: 'category' as const, data: snapshotLabels },
    yAxis: createScaledValueAxis({
      name: 'TOPO',
      values: estimatedRewardSeries,
      formatter: formatCompactNumber,
    }),
    series: [
      {
        name: '预计入账',
        type: 'bar',
        data: estimatedRewardSeries,
      },
    ],
  };
  const versionColumns = [
    {
      title: '版本槽',
      dataIndex: 'slot',
      width: 110,
      render: (v: string, r: any) => (
        <Space>
          <Tag color={v === 'newer' ? 'blue' : 'default'}>{v}</Tag>
          {!r.present && <Tag>空</Tag>}
          {r.selected_for_current_period && <Tag color="green">当前选中</Tag>}
          {r.selected_for_next_epoch && !r.selected_for_current_period && <Tag color="cyan">下 epoch 选中</Tag>}
        </Space>
      ),
    },
    { title: '生效 Period', dataIndex: 'effective_period', render: (_: number, r: any) => r.present ? formatNumber(r.effective_period || 0) : '-' },
    { title: '原始算力 raw_power', dataIndex: 'raw_power', render: (v: number) => formatNumber(v || 0) },
    { title: '当前是否生效', dataIndex: 'active_for_current_period', render: (v: boolean) => <Tag color={v ? 'green' : 'default'}>{v ? '是' : '否'}</Tag> },
    { title: '当前衰减周期', dataIndex: 'current_periods_elapsed', render: (v: number) => formatNumber(v || 0) },
    { title: '下一 epoch 是否生效', dataIndex: 'active_for_next_epoch', render: (v: boolean) => <Tag color={v ? 'green' : 'default'}>{v ? '是' : '否'}</Tag> },
  ];
  const calcColumns = [
    { title: '目标', dataIndex: 'label', width: 140 },
    { title: '目标 Period', dataIndex: 'target_period', render: (v: number) => formatNumber(v || 0) },
    { title: '选中版本', dataIndex: 'selected_slot', render: (v: string) => <Tag>{v || 'none'}</Tag> },
    { title: '基准 Period', dataIndex: 'base_period', render: (v: number) => formatNumber(v || 0) },
    { title: '基准原始算力', dataIndex: 'base_power', render: (v: number) => formatNumber(v || 0) },
    { title: '衰减周期数', dataIndex: 'periods_elapsed', render: (v: number) => formatNumber(v || 0) },
  ];
  useEffect(() => {
    setContributionPage(1);
    setContributionPageSize(10);
  }, [address]);
  useEventRefresh(['epoch_changed', 'power_period_advanced', 'history_sampled'], refresh);
  useEventRefresh(['history_sampled'], refreshSnapshotHistory);
  useEventRefresh(['history_sampled'], refreshPowerPeriodHistory);
  useEventRefresh(
    ['contribution_event', 'dapp_trade'],
    refreshContributionHistory,
    (event) => {
      const contributor = event.contributor || event.buyer;
      return !contributor || addressKey(String(contributor)) === addressKey(address);
    },
  );

  const doAction = async (name: string, fn: () => Promise<any>) => {
    setSubmitting(true);
    try {
      await fn();
      message.success(`${name}成功`);
      refresh();
    } catch {}
    setSubmitting(false);
  };

  return (
    <div>
      <div style={{ marginBottom: 16 }}><AddressTag address={address || ''} short={false} /></div>

      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={8}>
          <Card loading={loading}><Statistic title="TOPO 余额" value={formatTopo(balance.topo_octas || 0)} suffix="TOPO" /></Card>
        </Col>
        <Col span={8}>
          <Card loading={loading}>
            <Statistic title="原始算力" value={formatNumber(currentRawPower || 0)} />
            <div style={{ fontSize: 12, color: '#999' }}>有效: {formatNumber(power.effective_power || 0)}</div>
          </Card>
        </Col>
        <Col span={8}>
          <Card loading={loading}>
            <Statistic title="保证金" value={formatTopo(staking.deposit_octas || 0)} suffix="TOPO" />
            <Space direction="vertical" size={2} style={{ width: '100%', fontSize: 12 }}>
              <span style={{ color: '#999' }}>
                委托: <AddressTag address={staking.delegated_to || '0x0'} />
              </span>
              {staking.is_in_cooldown && (
                <Tooltip
                  title={
                    <div>
                      <div>{cooldownReason}</div>
                      {cooldownSource?.created_at && <div>本地记录: {formatTimestamp(cooldownSource.created_at)}</div>}
                    </div>
                  }
                >
                  <Space size={6} wrap>
                    <Tag color="orange" style={{ width: 'fit-content', marginInlineEnd: 0 }}>冷却中</Tag>
                    <Text type="secondary">
                      到期: {formatTimestamp(cooldownUntil)}
                      {cooldownRemaining > 0 ? `（剩余 ${formatDuration(cooldownRemaining)}）` : ''}
                    </Text>
                  </Space>
                </Tooltip>
              )}
              {staking.is_in_cooldown && <Text type="secondary">{cooldownReason}</Text>}
            </Space>
          </Card>
        </Col>
      </Row>

      <Card title="质押奖励" loading={loading} style={{ marginBottom: 16 }}>
        <Row gutter={[16, 16]}>
          <Col span={6}>
            <Statistic title="预计本 epoch 奖励" value={formatRewardAmount(rewards.estimated_epoch_reward_octas || 0)} />
          </Col>
          <Col span={6}>
            <Statistic title="预计手续费分成" value={formatRewardAmount(rewards.estimated_epoch_fee_octas || 0)} />
          </Col>
          <Col span={6}>
            <Statistic title="预计本 epoch 入账" value={formatRewardAmount(rewards.estimated_epoch_total_octas || 0)} />
          </Col>
          <Col span={6}>
            <Statistic title="当前奖励率" value={formatRewardRate(rewardRate)} />
          </Col>
        </Row>
        <Row gutter={[16, 16]} style={{ marginTop: 16 }}>
          <Col span={8}>
            <Statistic title="估算累计奖励" value={formatRewardAmount(cumulativeRewards.reward_octas || 0)} />
          </Col>
          <Col span={8}>
            <Statistic title="估算累计手续费" value={formatRewardAmount(cumulativeRewards.fee_octas || 0)} />
          </Col>
          <Col span={8}>
            <Statistic title="估算累计入账" value={formatRewardAmount(cumulativeRewards.total_estimated_reward_octas || 0)} suffix={`${cumulativeRewards.epochs || 0} epochs`} />
          </Col>
        </Row>
        <Space style={{ marginTop: 12 }}>
          <Tag color={rewards.auto_compound ? 'green' : 'default'}>{rewards.auto_compound ? '奖励自动复投到保证金' : '奖励方式未知'}</Tag>
          {rewards.is_validator_owner && <Tag color="blue">包含验证者佣金 {formatRewardAmount(rewards.estimated_owner_commission_octas || 0)}</Tag>}
          {rewards.delegated_to && rewards.delegated_to !== '0x0' ? <span style={{ color: '#666' }}>委托给 <AddressTag address={rewards.delegated_to} /></span> : <Tag>未委托</Tag>}
        </Space>
      </Card>

      <Card title="Power Store 当前状态" loading={loading} style={{ marginBottom: 16 }}>
        <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
          <Col xs={24} md={8}>
            <DetailPanel title="周期与衰减">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="当前 Epoch">{formatNumber(powerStore.current_epoch || 0)}</Descriptions.Item>
                <Descriptions.Item label="当前 Period">{formatNumber(powerStore.current_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一 Epoch Period">{formatNumber(powerStore.next_epoch_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="算力周期">{formatNumber(powerStore.power_period_in_epochs || 0)} Epoch</Descriptions.Item>
                <Descriptions.Item label="Clock 状态">{powerStore.period_clock_initialized ? <Tag color="green">已初始化</Tag> : <Tag color="orange">未初始化</Tag>}</Descriptions.Item>
                <Descriptions.Item label="Clock 倒计时">{powerStore.period_clock_initialized ? `${formatNumber(powerStore.period_clock_countdown || 0)} Epoch` : '-'}</Descriptions.Item>
                <Descriptions.Item label="保留系数">{formatNumber(powerStore.retention_bps || 0)} ({formatBps(powerStore.retention_bps || 0)})</Descriptions.Item>
                <Descriptions.Item label="每 Period 衰减">{formatNumber(powerStore.decay_bps || 0)} ({formatBps(powerStore.decay_bps || 0)})</Descriptions.Item>
              </Descriptions>
            </DetailPanel>
          </Col>
          <Col xs={24} md={8}>
            <DetailPanel title="原始 / 有效算力">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="当前选中版本"><Tag color="green">{currentCalculation.selected_slot || 'none'}</Tag></Descriptions.Item>
                <Descriptions.Item label="原始算力">{formatNumber(currentCalculation.base_power || 0)} @ P{formatNumber(currentCalculation.base_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="有效算力">{formatNumber(powerStore.staking_effective_power || power.effective_power || 0)}</Descriptions.Item>
                <Descriptions.Item label="当前衰减周期">{formatNumber(currentCalculation.periods_elapsed || 0)}</Descriptions.Item>
              </Descriptions>
            </DetailPanel>
          </Col>
          <Col xs={24} md={8}>
            <DetailPanel title="下一 Epoch 原始槽位">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="下一选中版本"><Tag color="cyan">{nextEpochCalculation.selected_slot || 'none'}</Tag></Descriptions.Item>
                <Descriptions.Item label="原始算力">{formatNumber(nextEpochCalculation.base_power || 0)} @ P{formatNumber(nextEpochCalculation.base_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一衰减周期">{formatNumber(nextEpochCalculation.periods_elapsed || 0)}</Descriptions.Item>
              </Descriptions>
            </DetailPanel>
          </Col>
        </Row>
        <Tabs
          size="small"
          items={[
            {
              key: 'versions',
              label: '原始算力槽位',
              children: (
                <Table
                  dataSource={versionRows}
                  columns={versionColumns}
                  rowKey="key"
                  pagination={false}
                  size="small"
                  scroll={{ x: 1180 }}
                />
              ),
            },
            {
              key: 'calculation',
              label: '衰减计算路径',
              children: (
                <Table
                  dataSource={calcRows}
                  columns={calcColumns}
                  rowKey="key"
                  pagination={false}
                  size="small"
                  scroll={{ x: 980 }}
                />
              ),
            },
          ]}
        />
      </Card>

      <Card
        title="历史观察"
        style={{ marginBottom: 16 }}
      >
        <Tabs
          defaultActiveKey="power"
          items={[
            {
              key: 'power',
              label: '算力',
              children: (
                <>
                  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
                    <HistoryWindowControl
                      limit={powerPeriodLimit}
                      offset={powerPeriodOffset}
                      total={powerPeriodData?.total || 0}
                      shown={powerTrendRows.length}
                      onLimitChange={setPowerPeriodLimit}
                      onOffsetChange={setPowerPeriodOffset}
                    />
                  </div>
                  <ReactECharts option={powerTrendChartOption} style={{ height: 300 }} />
                </>
              ),
            },
            {
              key: 'assets',
              label: '资产',
              children: (
                <>
                  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
                    <HistoryWindowControl
                      limit={snapshotLimit}
                      offset={snapshotOffset}
                      total={snapshotData?.total || 0}
                      shown={snapshots.length}
                      onLimitChange={setSnapshotLimit}
                      onOffsetChange={setSnapshotOffset}
                    />
                  </div>
                  <ReactECharts option={snapshotAssetChartOption} style={{ height: 300 }} />
                </>
              ),
            },
            {
              key: 'rewards',
              label: '奖励',
              children: (
                <>
                  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
                    <HistoryWindowControl
                      limit={snapshotLimit}
                      offset={snapshotOffset}
                      total={snapshotData?.total || 0}
                      shown={snapshots.length}
                      onLimitChange={setSnapshotLimit}
                      onOffsetChange={setSnapshotOffset}
                    />
                  </div>
                  <ReactECharts option={snapshotRewardChartOption} style={{ height: 300 }} />
                </>
              ),
            },
            {
              key: 'contributions',
              label: '贡献',
              children: (
                <>
                  <div style={{ color: '#666', marginBottom: 12 }}>
                    累计 {formatNumber(contributionData?.total_equity_amount || 0)} Equity / {formatNumber(contributionData?.total || 0)} 条
                  </div>
                  <Table
                    dataSource={pagedContributionEvents}
                    rowKey={(row: any) => `${row.tx_hash}:${row.event_index}`}
                    size="small"
                    pagination={{
                      current: contributionPage,
                      total: contributionEvents.length,
                      pageSize: contributionPageSize,
                      showSizeChanger: true,
                      pageSizeOptions: ['10', '50'],
                      onChange: (page, pageSize) => {
                        if (pageSize && pageSize !== contributionPageSize) {
                          setContributionPageSize(pageSize);
                          setContributionPage(1);
                          return;
                        }
                        setContributionPage(page);
                      },
                    }}
                    scroll={{ x: 900 }}
                    columns={[
                      { title: '时间', dataIndex: 'created_at', width: 170, render: (v: string) => formatTimestamp(v) },
                      { title: 'Period', dataIndex: 'period', width: 100, render: (v: number) => formatNumber(v || 0) },
                      { title: 'DApp 管理员', dataIndex: 'app_admin', width: 180, render: (v: string) => v ? <AddressTag address={v} /> : '-' },
                      { title: 'App 合约', dataIndex: 'app_address', width: 180, render: (v: string) => <AddressTag address={v} /> },
                      { title: '贡献 Equity', dataIndex: 'equity_amount', width: 130, render: (v: number) => formatNumber(v || 0) },
                      { title: '权益资产', dataIndex: 'equity_token', width: 180, render: (v: string) => v ? <AddressTag address={v} /> : '-' },
                      { title: '交易', dataIndex: 'tx_hash', width: 180, render: (v: string) => <AddressTag address={v} /> },
                    ]}
                  />
                </>
              ),
            },
          ]}
        />
      </Card>

      <Card title="操作区">
        <Row gutter={[16, 16]}>
          <Col xs={24} lg={12}>
            <Card size="small" title="铸造 TOPO">
              <div style={{ display: 'flex', gap: 8, width: '100%', alignItems: 'center' }}>
                <InputNumber value={mintAmount} onChange={(v) => setMintAmount(v || 0)} addonAfter="TOPO" min={0} style={{ flex: 1, minWidth: 0 }} />
                <Button loading={submitting} onClick={() => doAction('铸造', () => mintTopo({ recipient: address!, amount: topoToOctas(mintAmount) }))}>铸造</Button>
              </div>
            </Card>
          </Col>
          <Col xs={24} lg={12}>
            <Card size="small" title="算力写入">
              <div style={{ display: 'flex', gap: 8, width: '100%', alignItems: 'center' }}>
                <InputNumber value={powerVal} onChange={(v) => setPowerVal(v || 0)} min={0} style={{ flex: 1, minWidth: 0 }} />
                <Button loading={submitting} onClick={() => doAction('算力写入', () => stageSingle({ user_address: address!, power: powerVal }))}>写入</Button>
              </div>
            </Card>
          </Col>
          <Col xs={24} lg={12}>
            <Card size="small" title="保证金">
              <div style={{ display: 'flex', gap: 8, width: '100%', alignItems: 'center' }}>
                <InputNumber value={depositAmount} onChange={(v) => setDepositAmount(v || 0)} addonAfter="TOPO" min={0} style={{ flex: 1, minWidth: 0 }} />
                <Button loading={submitting} onClick={() => doAction('保证金', () => deposit({ user_address: address!, amount: topoToOctas(depositAmount) }))}>存入保证金</Button>
              </div>
            </Card>
          </Col>
          <Col xs={24} lg={12}>
            <Card size="small" title="委托给验证者">
              <div style={{ display: 'flex', gap: 8, width: '100%', alignItems: 'center' }}>
                <AddressSelect kind="validator" value={delegateTo} onChange={setDelegateTo} allowAdd={false} style={{ flex: 1, minWidth: 0 }} />
                <Button loading={submitting} onClick={() => doAction('委托', () => delegate({ user_address: address!, validator_address: delegateTo }))}>委托</Button>
              </div>
            </Card>
          </Col>
        </Row>
        <Space style={{ marginTop: 16 }}>
          <Button danger loading={submitting} onClick={() => Modal.confirm({ title: '确认取消委托?', onOk: () => doAction('取消委托', () => undelegate({ user_address: address! })) })}>取消委托</Button>
          <Button danger loading={submitting} onClick={() => Modal.confirm({ title: '确认提取保证金?', onOk: () => doAction('提取保证金', () => withdraw({ user_address: address! })) })}>提取保证金</Button>
        </Space>
      </Card>
    </div>
  );
}
