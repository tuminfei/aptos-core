import { useCallback, useEffect, useMemo, useState } from 'react';
import { Row, Col, Card, Statistic, Table, Tag, Progress, Space, Typography, Badge, Button, message, Modal } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getOverview } from '../services/dashboard';
import {
  getChainHistory,
  getConsensusValidatorPowerEpoch,
  getConsensusValidatorPowerHistory,
  sampleHistoryNow,
  sampleConsensusValidatorPowerNow,
} from '../services/history';
import { usePolling } from '../hooks/usePolling';
import { useWebSocket } from '../hooks/useWebSocket';
import { useEventRefresh } from '../hooks/useEventRefresh';
import { useNavigate } from 'react-router-dom';
import AddressTag from '../components/AddressTag';
import HistoryWindowControl from '../components/HistoryWindowControl';
import { createScaledValueAxis } from '../utils/chart';
import { formatCompactNumber, formatNumber, formatTimestamp, shortenAddress } from '../utils/format';

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
  const [historyLimit, setHistoryLimit] = useState(50);
  const [historyOffset, setHistoryOffset] = useState(0);
  const fetchOverview = useCallback(() => getOverview(), []);
  const fetchHistory = useCallback(() => getChainHistory(historyLimit, historyOffset), [historyLimit, historyOffset]);
  const { data, loading, refresh: refreshOverview } = usePolling(fetchOverview, 0);
  const { data: historyData, refresh: refreshHistory } = usePolling(fetchHistory, 0, [historyLimit, historyOffset]);
  const [consensusHistoryData, setConsensusHistoryData] = useState<any>(null);
  const [consensusHistoryLoading, setConsensusHistoryLoading] = useState(false);
  const { lastMessage } = useWebSocket();
  const [events, setEvents] = useState<{ time: string; type: string; detail: string }[]>([]);
  const [sampling, setSampling] = useState(false);
  const [consensusSampling, setConsensusSampling] = useState(false);
  const [consensusDetailOpen, setConsensusDetailOpen] = useState(false);
  const [consensusDetailLoading, setConsensusDetailLoading] = useState(false);
  const [consensusDetail, setConsensusDetail] = useState<any>(null);

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
  const powerPeriodClockInitialized = Boolean(power.power_period_clock_initialized);
  const powerPeriodClockCountdown = power.power_period_clock_countdown;
  const retentionBps = Number(power.retention_bps || 0);
  const decayBps = Math.max(0, 10000 - retentionBps);
  const activeValidators = Number(validators.active || 0);
  const totalValidators = Number(validators.total || 0);
  const pendingValidators = Number(validators.pending_active || 0) + Number(validators.pending_inactive || 0);
  const validatorActivePercent = totalValidators > 0 ? Math.round((activeValidators / totalValidators) * 100) : 0;
  const periodProgressPercent = Number(power.power_period_progress_percent || 0);
  const periodProgressEpochs = Number(power.power_period_progress_epochs || 0);

  const sortedSummary = useMemo(
    () => [...summary].sort((a: any, b: any) => Number(b.voting_power || 0) - Number(a.voting_power || 0)),
    [summary],
  );
  const totalVotingPower = sortedSummary.reduce((sum: number, v: any) => sum + Number(v.voting_power || 0), 0);
  const chainHistory = historyData?.history || [];
  const chainHistoryEpochs = useMemo(
    () => chainHistory.map((item: any) => Number(item.epoch || 0)).filter((epoch: number) => epoch > 0),
    [chainHistory],
  );
  const chainHistoryStartEpoch = chainHistoryEpochs.length ? Math.min(...chainHistoryEpochs) : 0;
  const chainHistoryEndEpoch = chainHistoryEpochs.length ? Math.max(...chainHistoryEpochs) : 0;
  const refreshConsensusHistory = useCallback(async () => {
    if (!chainHistoryStartEpoch || !chainHistoryEndEpoch) {
      setConsensusHistoryData(null);
      return;
    }
    setConsensusHistoryLoading(true);
    try {
      const result = await getConsensusValidatorPowerHistory(historyLimit, 0, true, {
        start_epoch: chainHistoryStartEpoch,
        end_epoch: chainHistoryEndEpoch,
      });
      setConsensusHistoryData(result);
    } catch {
      // API interceptor already reports the error.
    } finally {
      setConsensusHistoryLoading(false);
    }
  }, [chainHistoryStartEpoch, chainHistoryEndEpoch, historyLimit]);

  useEffect(() => {
    refreshConsensusHistory();
  }, [refreshConsensusHistory]);
  useEventRefresh(['history_sampled', 'consensus_validator_power_sampled'], refreshConsensusHistory);

  const consensusHistory = consensusHistoryData?.history || [];
  const consensusHistoryByEpoch = useMemo(() => {
    const map = new Map<number, any>();
    consensusHistory.forEach((item: any) => map.set(Number(item.epoch), item));
    return map;
  }, [consensusHistory]);
  const combinedHistory = chainHistory.map((item: any) => {
    const epoch = Number(item.epoch || 0);
    const consensus = consensusHistoryByEpoch.get(epoch);
    const consensusTotal = Number(consensus?.total_voting_power || 0);
    const hasConsensusVotingPower = Boolean(consensus) && consensusTotal > 0;
    return {
      ...item,
      consensus,
      has_consensus_voting_power: hasConsensusVotingPower,
      label: `E${epoch}`,
      total_staked_power: Number(item.total_staked_power || 0),
      total_voting_power: hasConsensusVotingPower ? consensusTotal : null,
    };
  });
  const combinedLabels = combinedHistory.map((item: any) => item.label);
  const totalStakedPowerSeries = combinedHistory.map((item: any) => item.total_staked_power);
  const consensusTotalVotingPowerSeries = combinedHistory.map((item: any) => item.total_voting_power);
  const validConsensusTotalVotingPowerSeries = consensusTotalVotingPowerSeries.filter(
    (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value),
  );

  const combinedPowerOption = {
    tooltip: {
      trigger: 'axis' as const,
      confine: true,
      enterable: true,
      formatter: (params: any) => {
        const items = Array.isArray(params) ? params : [params];
        const first = items[0] || {};
        const epoch = Number(String(first.axisValue || '').replace(/^E/, ''));
        const item = combinedHistory.find((entry: any) => Number(entry.epoch || 0) === epoch);
        if (!item) return first.axisValue || '';
        const consensus = item.consensus;
        const validators = [...(consensus?.validators || [])].slice(0, 12);
        const validatorRows = validators.map((validator: any) => {
          const share = (Number(validator.share_bps || 0) / 100).toFixed(2);
          return `
            <div style="display:flex;gap:12px;justify-content:space-between;white-space:nowrap;">
              <span>${shortenAddress(validator.peer_id || '', 10)}</span>
              <span>${formatCompactNumber(validator.voting_power || 0)} (${share}%)</span>
            </div>
          `;
        }).join('');
        const totalValidatorsInTooltip = consensus?.validators || [];
        const more = totalValidatorsInTooltip.length > validators.length
          ? `<div style="color:#999;margin-top:4px;">还有 ${totalValidatorsInTooltip.length - validators.length} 个验证者，点击图表查看完整明细</div>`
          : consensus ? '<div style="color:#999;margin-top:4px;">点击图表查看完整明细</div>' : '';
        return `
          <div style="min-width:280px;max-width:420px;">
            <div style="font-weight:600;margin-bottom:4px;">Epoch ${epoch}</div>
            <div>采样时间: ${formatTimestamp(item.sampled_at || '')}</div>
            <div>总质押算力: ${formatNumber(item.total_staked_power || 0)}</div>
            <div>实际总投票权: ${item.has_consensus_voting_power ? formatNumber(item.total_voting_power || 0) : '-'}</div>
            <div>实际验证者: ${item.has_consensus_voting_power ? `${consensus.captured_validator_count || 0} / ${consensus.validator_count || 0}` : '-'}</div>
            <div style="margin-top:8px;border-top:1px solid #eee;padding-top:6px;">${validatorRows || '暂无实际验证者明细'}</div>
            ${more}
          </div>
        `;
      },
    },
    legend: { top: 0 },
    grid: { left: 48, right: 48, top: 44, bottom: 32, containLabel: true },
    xAxis: { type: 'category' as const, data: combinedLabels },
    yAxis: [
      createScaledValueAxis({
        name: '算力/投票权',
        values: [...totalStakedPowerSeries, ...validConsensusTotalVotingPowerSeries],
        formatter: formatCompactNumber,
        position: 'left',
      }),
    ],
    series: [
      {
        name: '总质押算力',
        type: 'line',
        smooth: true,
        data: totalStakedPowerSeries,
      },
      {
        name: '实际总投票权',
        type: 'line',
        smooth: true,
        connectNulls: false,
        data: consensusTotalVotingPowerSeries,
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

  const handleConsensusSampleNow = async () => {
    setConsensusSampling(true);
    try {
      const result = await sampleConsensusValidatorPowerNow();
      if (result.success) {
        message.success('共识投票权快照已记录');
      } else {
        message.warning(result.reason || '未采集到共识投票权');
      }
      refreshConsensusHistory();
    } catch {}
    setConsensusSampling(false);
  };

  const openConsensusDetail = async (epoch: number) => {
    setConsensusDetailOpen(true);
    setConsensusDetailLoading(true);
    setConsensusDetail(null);
    try {
      const detail = await getConsensusValidatorPowerEpoch(epoch);
      setConsensusDetail(detail);
    } catch {}
    setConsensusDetailLoading(false);
  };

  const pieOption = {
    tooltip: { trigger: 'item' as const },
    legend: { orient: 'vertical' as const, right: 0, top: 'middle' },
    series: [{
      type: 'pie',
      radius: ['45%', '70%'],
      center: ['38%', '50%'],
      data: sortedSummary.map((v: any) => ({ name: v.display_name || v.address?.slice(0, 10), value: v.voting_power })),
      label: { show: false },
      tooltip: {
        formatter: (params: any) => `${params.name}<br/>投票权: ${formatNumber(params.value)}<br/>占比: ${params.percent}%`,
      },
    }],
  };

  const columns = [
    { title: '验证者', dataIndex: 'address', render: (v: string, r: any) => <AddressTag address={v} name={r.display_name} showAddress /> },
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

  const consensusDetailTotal = Number(consensusDetail?.total_voting_power || 0);
  const consensusDetailColumns = [
    {
      title: 'Peer ID',
      dataIndex: 'peer_id',
      render: (v: string) => <AddressTag address={v} />,
    },
    {
      title: '投票权',
      dataIndex: 'voting_power',
      align: 'right' as const,
      render: (v: number) => (
        <Space direction="vertical" size={0} style={{ width: '100%' }}>
          <Text>{formatNumber(v || 0)}</Text>
          <Progress percent={consensusDetailTotal > 0 ? Number(((Number(v || 0) / consensusDetailTotal) * 100).toFixed(2)) : 0} size="small" showInfo={false} />
        </Space>
      ),
    },
    {
      title: '占比',
      dataIndex: 'share_bps',
      align: 'right' as const,
      render: (v: number) => `${(Number(v || 0) / 100).toFixed(2)}%`,
    },
  ];

  const handleConsensusChartClick = (params: any) => {
    const epoch = Number(String(params?.name || params?.axisValue || '').replace(/^E/, ''));
    if (epoch > 0) {
      openConsensusDetail(epoch);
    }
  };

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
              <Text type="secondary">{formatEpochInterval(powerPeriodInEpochs)}，链上倒计时驱动</Text>
              <Text type="secondary">已走 {periodProgressEpochs || 0} / {powerPeriodInEpochs || '-'} 个 Epoch</Text>
              <Text type="secondary">距离下个 Period 还有 {powerPeriodClockInitialized ? `${epochsUntilNextPeriod}E` : '-'}</Text>
              <Text type="secondary">clock: {powerPeriodClockInitialized ? String(powerPeriodClockCountdown ?? 0) : '未初始化'}</Text>
              <Text type="secondary">保留 {formatBps(retentionBps)}，衰减 {formatBps(decayBps)}</Text>
            </Space>
          </Card>
        </Col>
      </Row>

      <Card
        title="全局/共识历史趋势"
        loading={consensusHistoryLoading}
        extra={(
          <Space wrap>
            <HistoryWindowControl
              limit={historyLimit}
              offset={historyOffset}
              total={historyData?.total || 0}
              shown={chainHistory.length}
              onLimitChange={setHistoryLimit}
              onOffsetChange={setHistoryOffset}
            />
            <Button size="small" loading={sampling} onClick={handleSampleNow}>记录快照</Button>
            <Button size="small" loading={consensusSampling} onClick={handleConsensusSampleNow}>采集投票权</Button>
          </Space>
        )}
        style={{ marginBottom: 16 }}
      >
        <Text type="secondary">总质押算力 / 节点共识层实际总投票权；实际验证者明细在鼠标悬停时显示</Text>
        <ReactECharts
          option={combinedPowerOption}
          style={{ height: 280 }}
          onEvents={{ click: handleConsensusChartClick }}
        />
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

      <Modal
        title={`Epoch ${consensusDetail?.epoch || ''} 实际投票权明细`}
        open={consensusDetailOpen}
        onCancel={() => setConsensusDetailOpen(false)}
        footer={null}
        width={820}
      >
        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Space wrap>
            <Tag color="blue">总投票权 {formatNumber(consensusDetailTotal)}</Tag>
            <Tag>验证者 {consensusDetail?.captured_validator_count || 0} / {consensusDetail?.validator_count || 0}</Tag>
            {consensusDetail?.source_url ? <Text type="secondary">{shortenAddress(consensusDetail.source_url, 22)}</Text> : null}
          </Space>
          <Table
            loading={consensusDetailLoading}
            dataSource={consensusDetail?.validators || []}
            columns={consensusDetailColumns}
            rowKey="peer_id"
            size="small"
            pagination={false}
            scroll={{ x: 640, y: 420 }}
          />
        </Space>
      </Modal>
    </div>
  );
}
