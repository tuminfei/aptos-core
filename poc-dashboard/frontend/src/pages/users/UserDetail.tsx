import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Row, Col, Card, Statistic, Button, InputNumber, Space, Modal, message, Tag, Descriptions, Table } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getUser, getPowerHistory, getUserContributionEvents } from '../../services/user';
import { getUserSnapshotHistory } from '../../services/history';
import { mintTopo } from '../../services/governance';
import { stageSingle } from '../../services/power';
import { deposit, delegate, undelegate, withdraw } from '../../services/staking';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressTag from '../../components/AddressTag';
import AddressSelect from '../../components/AddressSelect';
import HistoryWindowControl from '../../components/HistoryWindowControl';
import { createScaledValueAxis } from '../../utils/chart';
import { formatCompactNumber, formatNumber, formatRewardAmount, formatRewardRate, formatTimestamp, formatTopo, topoToOctas } from '../../utils/format';

export default function UserDetail() {
  const { address } = useParams<{ address: string }>();
  const [snapshotLimit, setSnapshotLimit] = useState(200);
  const [snapshotOffset, setSnapshotOffset] = useState(0);
  const fetchUser = useCallback(() => getUser(address!), [address]);
  const fetchHistory = useCallback(() => getPowerHistory(address!), [address]);
  const fetchSnapshotHistory = useCallback(() => getUserSnapshotHistory(address!, snapshotLimit, snapshotOffset), [address, snapshotLimit, snapshotOffset]);
  const fetchContributionHistory = useCallback(() => getUserContributionEvents(address!, 50), [address]);
  const { data, loading, refresh } = usePolling(fetchUser, 0, [address]);
  const { data: historyData, refresh: refreshPowerHistory } = usePolling(fetchHistory, 0, [address]);
  const { data: snapshotData, refresh: refreshSnapshotHistory } = usePolling(fetchSnapshotHistory, 0, [address, snapshotLimit, snapshotOffset]);
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
  const history = historyData?.history || [];
  const snapshots = snapshotData?.history || [];
  const cumulativeRewards = snapshotData?.cumulative_rewards || {};
  const contributionEvents = contributionData?.events || [];
  const formatBps = (bps: number) => `${(Number(bps || 0) / 100).toFixed(2)}%`;
  const currentCalculation = powerStore.current_calculation || {};
  const nextEpochCalculation = powerStore.next_epoch_calculation || {};
  const powerGap = powerStore.power_gap || {};
  const versionRows = (powerStore.version_rows || []).map((row: any) => ({ key: row.slot, ...row }));
  const calcRows = [
    { key: 'current', label: '当前 period', ...currentCalculation },
    { key: 'next', label: '下一 epoch period', ...nextEpochCalculation },
  ];
  const historyPowers = history.map((h: any) => Number(h.power || 0));
  const hasHistoryPowers = historyPowers.length > 0;
  const powerMin = hasHistoryPowers ? Math.min(...historyPowers) : 0;
  const powerMax = hasHistoryPowers ? Math.max(...historyPowers) : 0;
  const powerRange = powerMax - powerMin;
  const flatPowerPadding = Math.max(1, Math.ceil(Math.max(powerMax, 1) * 0.05));
  const historyYAxisMin = hasHistoryPowers && powerRange > 0 ? powerMin : Math.max(0, powerMin - flatPowerPadding);
  const historyYAxisMax = hasHistoryPowers && powerRange > 0 ? powerMax : powerMax + flatPowerPadding;

  const chartOption = {
    grid: { left: 56, right: 32, top: 32, bottom: 32, containLabel: true },
    xAxis: { type: 'category' as const, data: history.map((h: any) => `P${h.period}`) },
    yAxis: {
      type: 'value' as const,
      min: historyYAxisMin,
      max: historyYAxisMax,
      scale: true,
      axisLabel: {
        formatter: (v: number) => formatCompactNumber(v),
        showMinLabel: true,
        showMaxLabel: true,
      },
    },
    series: [{
      type: 'line',
      data: historyPowers,
      smooth: true,
      areaStyle: {},
      markPoint: {
        symbolSize: 56,
        label: { formatter: ({ value }: any) => formatNumber(value) },
        data: [
          { type: 'max', name: '最大值' },
          { type: 'min', name: '最小值' },
        ],
      },
    }],
    tooltip: { trigger: 'axis' as const },
  };
  const snapshotLabels = snapshots.map((h: any) => {
    const date = new Date(h.sampled_at);
    return Number.isNaN(date.getTime()) ? h.sampled_at : date.toLocaleTimeString();
  });
  const effectivePowerSeries = snapshots.map((h: any) => Number(h.effective_power || 0));
  const committedPowerSeries = snapshots.map((h: any) => Number(h.committed_power || 0));
  const depositSeries = snapshots.map((h: any) => Number(h.deposit_octas || 0) / 1e8);
  const balanceSeries = snapshots.map((h: any) => Number(h.balance_octas || 0) / 1e8);
  const estimatedRewardSeries = snapshots.map((h: any) => Number(h.estimated_epoch_total_octas || 0) / 1e8);
  const snapshotChartOption = {
    tooltip: { trigger: 'axis' as const },
    legend: { top: 0 },
    grid: { left: 56, right: 72, top: 44, bottom: 32, containLabel: true },
    xAxis: { type: 'category' as const, data: snapshotLabels },
    yAxis: [
      createScaledValueAxis({
        name: '算力',
        values: [...effectivePowerSeries, ...committedPowerSeries],
        formatter: formatCompactNumber,
      }),
      createScaledValueAxis({
        name: 'TOPO',
        values: [...depositSeries, ...balanceSeries, ...estimatedRewardSeries],
        formatter: formatCompactNumber,
      }),
    ],
    series: [
      {
        name: '有效算力',
        type: 'line',
        smooth: true,
        data: effectivePowerSeries,
      },
      {
        name: '已提交算力',
        type: 'line',
        smooth: true,
        data: committedPowerSeries,
      },
      {
        name: '保证金',
        type: 'line',
        yAxisIndex: 1,
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
      {
        name: '预计入账',
        type: 'bar',
        yAxisIndex: 1,
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
    { title: '当前衰减后算力', dataIndex: 'current_decayed_power', render: (v: number) => formatNumber(v || 0) },
    { title: '下一 epoch 是否生效', dataIndex: 'active_for_next_epoch', render: (v: boolean) => <Tag color={v ? 'green' : 'default'}>{v ? '是' : '否'}</Tag> },
    { title: '下一 epoch 衰减后算力', dataIndex: 'next_epoch_decayed_power', render: (v: number) => formatNumber(v || 0) },
  ];
  const calcColumns = [
    { title: '目标', dataIndex: 'label', width: 140 },
    { title: '目标 Period', dataIndex: 'target_period', render: (v: number) => formatNumber(v || 0) },
    { title: '选中版本', dataIndex: 'selected_slot', render: (v: string) => <Tag>{v || 'none'}</Tag> },
    { title: '基准 Period', dataIndex: 'base_period', render: (v: number) => formatNumber(v || 0) },
    { title: '基准原始算力', dataIndex: 'base_power', render: (v: number) => formatNumber(v || 0) },
    { title: '衰减周期数', dataIndex: 'periods_elapsed', render: (v: number) => formatNumber(v || 0) },
    { title: '计算值', dataIndex: 'calculated_power', render: (v: number) => formatNumber(v || 0) },
    { title: '链上返回值', dataIndex: 'chain_power', render: (v: number) => formatNumber(v || 0) },
    { title: '差值', dataIndex: 'delta', render: (v: number) => formatNumber(v || 0) },
  ];

  useEventRefresh(['epoch_changed', 'power_period_advanced', 'history_sampled'], refresh);
  useEventRefresh(['power_period_advanced'], refreshPowerHistory);
  useEventRefresh(['history_sampled'], refreshSnapshotHistory);
  useEventRefresh(
    ['contribution_event', 'dapp_trade'],
    refreshContributionHistory,
    (event) => {
      const contributor = event.contributor || event.buyer;
      return !contributor || String(contributor).toLowerCase() === String(address || '').toLowerCase();
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
            <Statistic title="已提交算力" value={formatNumber(power.committed_power || 0)} />
            <div style={{ fontSize: 12, color: '#999' }}>有效: {formatNumber(power.effective_power || 0)} | 下周期: {formatNumber(power.power_for_next_epoch || 0)}</div>
          </Card>
        </Col>
        <Col span={8}>
          <Card loading={loading}>
            <Statistic title="保证金" value={formatTopo(staking.deposit_octas || 0)} suffix="TOPO" />
            <div style={{ fontSize: 12, color: '#999' }}>
              委托: <AddressTag address={staking.delegated_to || '0x0'} />
              {staking.is_in_cooldown && <span style={{ color: 'orange' }}> 冷却中</span>}
            </div>
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

      <Card title="Power Store 原始版本与衰减" loading={loading} style={{ marginBottom: 16 }}>
        <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
          <Col xs={24} md={8}>
            <Card size="small" title="周期与衰减">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="当前 Epoch">{formatNumber(powerStore.current_epoch || 0)}</Descriptions.Item>
                <Descriptions.Item label="当前 Period">{formatNumber(powerStore.current_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一 Epoch Period">{formatNumber(powerStore.next_epoch_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="算力周期">{formatNumber(powerStore.power_period_in_epochs || 0)} Epoch</Descriptions.Item>
                <Descriptions.Item label="保留系数">{formatNumber(powerStore.retention_bps || 0)} ({formatBps(powerStore.retention_bps || 0)})</Descriptions.Item>
                <Descriptions.Item label="每 Period 衰减">{formatNumber(powerStore.decay_bps || 0)} ({formatBps(powerStore.decay_bps || 0)})</Descriptions.Item>
              </Descriptions>
            </Card>
          </Col>
          <Col xs={24} md={8}>
            <Card size="small" title="当前算力">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="PowerStore 当前">{formatNumber(power.committed_power || 0)}</Descriptions.Item>
                <Descriptions.Item label="Staking 有效">{formatNumber(powerStore.staking_effective_power || power.effective_power || 0)}</Descriptions.Item>
                <Descriptions.Item label="Staking - PowerStore">{formatNumber(powerGap.staking_effective_minus_power_store || 0)}</Descriptions.Item>
                <Descriptions.Item label="当前选中版本"><Tag color="green">{currentCalculation.selected_slot || 'none'}</Tag></Descriptions.Item>
                <Descriptions.Item label="当前基准">{formatNumber(currentCalculation.base_power || 0)} @ P{formatNumber(currentCalculation.base_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="当前衰减周期">{formatNumber(currentCalculation.periods_elapsed || 0)}</Descriptions.Item>
              </Descriptions>
            </Card>
          </Col>
          <Col xs={24} md={8}>
            <Card size="small" title="下一 Epoch 算力">
              <Descriptions column={1} size="small">
                <Descriptions.Item label="PowerStore 下一">{formatNumber(power.power_for_next_epoch || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一 - 当前">{formatNumber(powerGap.next_epoch_minus_current || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一选中版本"><Tag color="cyan">{nextEpochCalculation.selected_slot || 'none'}</Tag></Descriptions.Item>
                <Descriptions.Item label="下一基准">{formatNumber(nextEpochCalculation.base_power || 0)} @ P{formatNumber(nextEpochCalculation.base_period || 0)}</Descriptions.Item>
                <Descriptions.Item label="下一衰减周期">{formatNumber(nextEpochCalculation.periods_elapsed || 0)}</Descriptions.Item>
                <Descriptions.Item label="计算差值">{formatNumber(nextEpochCalculation.delta || 0)}</Descriptions.Item>
              </Descriptions>
            </Card>
          </Col>
        </Row>
        <Row gutter={[16, 16]}>
          <Col xs={24}>
            <Table
              title={() => '双版本原始算力槽位'}
              dataSource={versionRows}
              columns={versionColumns}
              rowKey="key"
              pagination={false}
              size="small"
              scroll={{ x: 1180 }}
            />
          </Col>
          <Col xs={24}>
            <Table
              title={() => '衰减计算路径'}
              dataSource={calcRows}
              columns={calcColumns}
              rowKey="key"
              pagination={false}
              size="small"
              scroll={{ x: 980 }}
            />
          </Col>
        </Row>
      </Card>

      <Card
        title="算力历史"
        extra={<span style={{ color: '#666' }}>最小 {formatNumber(powerMin)} / 最大 {formatNumber(powerMax)}</span>}
        style={{ marginBottom: 16 }}
      >
        <ReactECharts option={chartOption} style={{ height: 250 }} />
      </Card>

      <Card
        title="本地快照历史"
        extra={(
          <HistoryWindowControl
            limit={snapshotLimit}
            offset={snapshotOffset}
            total={snapshotData?.total || 0}
            shown={snapshots.length}
            onLimitChange={setSnapshotLimit}
            onOffsetChange={setSnapshotOffset}
          />
        )}
        style={{ marginBottom: 16 }}
      >
        <ReactECharts option={snapshotChartOption} style={{ height: 300 }} />
      </Card>

      <Card
        title="贡献事件历史"
        extra={<span style={{ color: '#666' }}>累计 {formatNumber(contributionData?.total_equity_amount || 0)} Equity / {formatNumber(contributionData?.total || 0)} 条</span>}
        style={{ marginBottom: 16 }}
      >
        <Table
          dataSource={contributionEvents}
          rowKey={(row: any) => `${row.tx_hash}:${row.event_index}`}
          size="small"
          pagination={{ pageSize: 10, showSizeChanger: false }}
          scroll={{ x: 900 }}
          columns={[
            { title: '时间', dataIndex: 'created_at', width: 170, render: (v: string) => formatTimestamp(v) },
            { title: 'DApp 管理员', dataIndex: 'app_admin', width: 180, render: (v: string) => v ? <AddressTag address={v} /> : '-' },
            { title: 'App 合约', dataIndex: 'app_address', width: 180, render: (v: string) => <AddressTag address={v} /> },
            { title: '贡献 Equity', dataIndex: 'equity_amount', width: 130, render: (v: number) => formatNumber(v || 0) },
            { title: '权益资产', dataIndex: 'equity_token', width: 180, render: (v: string) => v ? <AddressTag address={v} /> : '-' },
            { title: '交易', dataIndex: 'tx_hash', width: 180, render: (v: string) => <AddressTag address={v} /> },
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
            <Card size="small" title="设置算力">
              <div style={{ display: 'flex', gap: 8, width: '100%', alignItems: 'center' }}>
                <InputNumber value={powerVal} onChange={(v) => setPowerVal(v || 0)} min={0} style={{ flex: 1, minWidth: 0 }} />
                <Button loading={submitting} onClick={() => doAction('设置算力', () => stageSingle({ user_address: address!, power: powerVal }))}>设置</Button>
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
