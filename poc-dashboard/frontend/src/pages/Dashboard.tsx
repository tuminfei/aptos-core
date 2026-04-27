import { useCallback, useEffect, useMemo, useState } from 'react';
import { Row, Col, Card, Statistic, Table, Tag, Progress, Space, Typography, Badge, Button, message } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getOverview } from '../services/dashboard';
import { getChainHistory, sampleHistoryNow } from '../services/history';
import { usePolling } from '../hooks/usePolling';
import { useWebSocket } from '../hooks/useWebSocket';
import { useEventRefresh } from '../hooks/useEventRefresh';
import { useNavigate } from 'react-router-dom';
import AddressTag from '../components/AddressTag';
import { formatNumber, formatTimestamp } from '../utils/format';

const { Text } = Typography;

function formatBps(bps: number): string {
  return `${(Number(bps || 0) / 100).toFixed(2)}%`;
}

function formatEpochInterval(epochs: number): string {
  if (!epochs) return '-';
  return epochs === 1 ? '每个 Epoch' : `每 ${epochs} 个 Epoch`;
}

function formatCooldown(seconds: number): string {
  if (!seconds) return '-';
  const days = seconds / 86400;
  return days >= 1 ? `${days.toFixed(days % 1 === 0 ? 0 : 1)} 天` : `${seconds} 秒`;
}

export default function Dashboard() {
  const navigate = useNavigate();
  const fetchOverview = useCallback(() => getOverview(), []);
  const fetchHistory = useCallback(() => getChainHistory(200), []);
  const { data, loading, refresh: refreshOverview } = usePolling(fetchOverview, 0);
  const { data: historyData, refresh: refreshHistory } = usePolling(fetchHistory, 0);
  const { lastMessage } = useWebSocket();
  const [events, setEvents] = useState<{ time: string; type: string; detail: string }[]>([]);
  const [sampling, setSampling] = useState(false);

  useEffect(() => {
    if (lastMessage) {
      setEvents((prev) => [
        { time: new Date().toLocaleTimeString(), type: lastMessage.type, detail: JSON.stringify(lastMessage.data) },
        ...prev.slice(0, 19),
      ]);
    }
  }, [lastMessage]);

  useEventRefresh(['chain_tick', 'epoch_changed', 'validator_set_changed', 'power_period_advanced'], refreshOverview);
  useEventRefresh(['history_sampled'], refreshHistory);

  const chain = data?.chain || {};
  const validators = data?.validators || {};
  const power = data?.power || {};
  const staking = data?.staking || {};
  const summary = data?.active_validators_summary || [];
  const currentEpoch = Number(chain.epoch || 0);
  const powerPeriodInEpochs = Number(power.power_period_in_epochs || 0);
  const currentPowerPeriod = Number(power.current_period || 0);
  const epochsUntilNextPeriod = Number(power.epochs_until_next_period || 0);
  const nextPowerPeriodEpoch = powerPeriodInEpochs > 0 ? currentEpoch + epochsUntilNextPeriod : 0;
  const retentionBps = Number(power.retention_bps || 0);
  const decayBps = Math.max(0, 10000 - retentionBps);
  const activeValidators = Number(validators.active || 0);
  const totalValidators = Number(validators.total || 0);
  const pendingValidators = Number(validators.pending_active || 0) + Number(validators.pending_inactive || 0);
  const validatorActivePercent = totalValidators > 0 ? Math.round((activeValidators / totalValidators) * 100) : 0;
  const periodEpochPosition = powerPeriodInEpochs > 0 ? (currentEpoch % powerPeriodInEpochs) + 1 : 0;
  const periodProgressPercent = powerPeriodInEpochs > 0 ? Math.round((periodEpochPosition / powerPeriodInEpochs) * 100) : 0;
  const periodStartEpoch = powerPeriodInEpochs > 0 ? currentPowerPeriod * powerPeriodInEpochs : 0;
  const periodEndEpoch = powerPeriodInEpochs > 0 ? periodStartEpoch + powerPeriodInEpochs - 1 : 0;

  const sortedSummary = useMemo(
    () => [...summary].sort((a: any, b: any) => Number(b.voting_power || 0) - Number(a.voting_power || 0)),
    [summary],
  );
  const totalVotingPower = sortedSummary.reduce((sum: number, v: any) => sum + Number(v.voting_power || 0), 0);
  const chainHistory = historyData?.history || [];
  const historyLabels = chainHistory.map((item: any) => {
    const date = new Date(item.sampled_at);
    return Number.isNaN(date.getTime()) ? item.sampled_at : date.toLocaleTimeString();
  });

  const historyOption = {
    tooltip: { trigger: 'axis' as const },
    legend: { top: 0 },
    grid: { left: 48, right: 56, top: 44, bottom: 32 },
    xAxis: { type: 'category' as const, data: historyLabels },
    yAxis: [
      { type: 'value' as const, name: '算力/区块' },
      { type: 'value' as const, name: '验证者', minInterval: 1 },
    ],
    series: [
      {
        name: '总质押算力',
        type: 'line',
        smooth: true,
        data: chainHistory.map((item: any) => Number(item.total_staked_power || 0)),
      },
      {
        name: '区块高度',
        type: 'line',
        smooth: true,
        data: chainHistory.map((item: any) => Number(item.block_height || 0)),
      },
      {
        name: '活跃验证者',
        type: 'line',
        yAxisIndex: 1,
        smooth: true,
        data: chainHistory.map((item: any) => Number(item.active_validator_count || 0)),
      },
    ],
  };

  const handleSampleNow = async () => {
    setSampling(true);
    try {
      await sampleHistoryNow();
      message.success('历史快照已记录');
      refreshHistory();
    } catch {}
    setSampling(false);
  };

  const pieOption = {
    tooltip: { trigger: 'item' as const },
    legend: { orient: 'vertical' as const, right: 0, top: 'middle' },
    series: [{
      type: 'pie',
      radius: ['45%', '70%'],
      center: ['38%', '50%'],
      data: sortedSummary.map((v: any) => ({ name: v.address?.slice(0, 10), value: v.voting_power })),
      label: { show: false },
      tooltip: {
        formatter: (params: any) => `${params.name}<br/>投票权: ${formatNumber(params.value)}<br/>占比: ${params.percent}%`,
      },
    }],
  };

  const columns = [
    { title: '地址', dataIndex: 'address', render: (v: string) => <AddressTag address={v} /> },
    {
      title: '投票权',
      dataIndex: 'voting_power',
      align: 'right' as const,
      render: (v: number) => (
        <Space direction="vertical" size={0} style={{ width: '100%' }}>
          <Text>{formatNumber(v || 0)}</Text>
          <Progress percent={totalVotingPower > 0 ? Number(((Number(v || 0) / totalVotingPower) * 100).toFixed(2)) : 0} size="small" showInfo={false} />
        </Space>
      ),
    },
    {
      title: '占比',
      align: 'right' as const,
      render: (_: unknown, row: any) => `${totalVotingPower > 0 ? ((Number(row.voting_power || 0) / totalVotingPower) * 100).toFixed(2) : '0.00'}%`,
    },
    { title: '委托者', dataIndex: 'delegator_count', align: 'right' as const },
    {
      title: '出块成功率',
      dataIndex: 'success_rate',
      align: 'right' as const,
      render: (v: number) => <Tag color={v >= 0.99 ? 'green' : 'orange'}>{(Number(v || 0) * 100).toFixed(1)}%</Tag>,
    },
  ];

  return (
    <div>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} md={12} xl={6}>
          <Card loading={loading}>
            <Statistic title="当前 Epoch" value={currentEpoch} />
            <Space direction="vertical" size={2} style={{ marginTop: 8 }}>
              <Text type="secondary">Chain ID {chain.chain_id || 0}</Text>
              <Text type="secondary">区块 {formatNumber(chain.block_height || 0)} · 版本 {formatNumber(chain.ledger_version || 0)}</Text>
              <Text type="secondary">{formatTimestamp(chain.ledger_timestamp || '')}</Text>
            </Space>
          </Card>
        </Col>
        <Col xs={24} md={12} xl={6}>
          <Card loading={loading}>
            <Statistic title="验证者状态" value={`${activeValidators} / ${totalValidators}`} />
            <Progress percent={validatorActivePercent} size="small" status={pendingValidators > 0 ? 'active' : 'success'} />
            <Space style={{ marginTop: 8 }}>
              <Badge status={pendingValidators > 0 ? 'warning' : 'success'} text={pendingValidators > 0 ? `待处理 ${pendingValidators}` : '全部活跃'} />
            </Space>
          </Card>
        </Col>
        <Col xs={24} md={12} xl={6}>
          <Card loading={loading}>
            <Statistic title="总质押算力" value={formatNumber(staking.total_staked_power || 0)} />
            <Space direction="vertical" size={2} style={{ marginTop: 8 }}>
              <Text type="secondary">octas_per_power: {formatNumber(staking.octas_per_power || 0)}</Text>
              <Text type="secondary">冷却期: {formatCooldown(Number(staking.cooldown_secs || 0))}</Text>
            </Space>
          </Card>
        </Col>
        <Col xs={24} md={12} xl={6}>
          <Card loading={loading}>
            <Statistic title="当前算力 Period" value={currentPowerPeriod} />
            <Progress percent={periodProgressPercent} size="small" />
            <Space direction="vertical" size={2} style={{ marginTop: 8 }}>
              <Text type="secondary">{formatEpochInterval(powerPeriodInEpochs)}，Epoch {periodStartEpoch}-{periodEndEpoch}</Text>
              <Text type="secondary">当前第 {periodEpochPosition || '-'} / {powerPeriodInEpochs || '-'} 个 Epoch</Text>
              <Text type="secondary">下次衰减 Epoch {nextPowerPeriodEpoch || '-'}，还有 {epochsUntilNextPeriod || 0}E</Text>
              <Text type="secondary">保留 {formatBps(retentionBps)}，衰减 {formatBps(decayBps)}</Text>
            </Space>
          </Card>
        </Col>
      </Row>

      <Card
        title="全局历史趋势"
        extra={<Button size="small" loading={sampling} onClick={handleSampleNow}>记录快照</Button>}
        style={{ marginBottom: 16 }}
      >
        <ReactECharts option={historyOption} style={{ height: 280 }} />
      </Card>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} xl={10}>
          <Card title="验证者投票权分布" loading={loading}>
            <ReactECharts option={pieOption} style={{ height: 300 }} />
          </Card>
        </Col>
        <Col xs={24} xl={14}>
          <Card title="活跃验证者明细" loading={loading}>
            <Table
              dataSource={sortedSummary}
              columns={columns}
              rowKey="address"
              size="small"
              pagination={false}
              scroll={{ x: 760 }}
              onRow={(r: any) => ({ onClick: () => navigate(`/validators/${r.address}`), style: { cursor: 'pointer' } })}
            />
          </Card>
        </Col>
      </Row>

      <Card title="实时事件流" size="small">
        {events.length === 0 ? <span style={{ color: '#999' }}>等待事件...</span> : (
          <div style={{ maxHeight: 200, overflow: 'auto' }}>
            {events.map((e, i) => (
              <div key={i} style={{ fontSize: 12, padding: '2px 0', borderBottom: '1px solid #f0f0f0' }}>
                <Tag>{e.time}</Tag> <Tag color="blue">{e.type}</Tag> {e.detail}
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
