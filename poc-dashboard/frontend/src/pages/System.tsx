import { useCallback, useMemo, useState } from 'react';
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
  updateGovernanceConfig,
  upgradeFramework,
} from '../services/governance';
import {
  getPowerStore,
  initializePowerPeriodClock,
  queryPowerStoreUsers,
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
import { formatNumber, formatTimestamp, topoToOctas } from '../utils/format';

const { Text } = Typography;

function formatBps(bps: number): string {
  return `${(Number(bps || 0) / 100).toFixed(2)}%`;
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
  const { data: chain, refresh: refreshChain } = usePolling(fetchChain, 10000);
  const { data: config, refresh: refreshConfig } = usePolling(fetchConfig, 30000);
  const { data: powerStore, refresh: refreshPowerStore } = usePolling(fetchPowerStore, 0);

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
  const [operatorAddr, setOperatorAddr] = useState('');
  const [stageAddr, setStageAddr] = useState('');
  const [stagePower, setStagePower] = useState<number>(0);
  const [queryAddr, setQueryAddr] = useState('');
  const [targetPeriod, setTargetPeriod] = useState<number | null>(null);
  const [queryRows, setQueryRows] = useState<any[]>([]);
  const [batchPeriod, setBatchPeriod] = useState<number>(0);
  const [batchText, setBatchText] = useState('');
  const [batchPreview, setBatchPreview] = useState<{ address: string; power: number }[]>([]);
  const [submitting, setSubmitting] = useState(false);

  const refreshAll = () => {
    refreshChain();
    refreshConfig();
    refreshPowerStore();
  };

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
      message.warning('没有解析到有效的批量打点记录');
    }
  };

  const handleBatchStage = async () => {
    const updates = batchPreview.length ? batchPreview : parseBatchUpdates(batchText);
    if (!updates.length) {
      message.warning('没有有效的批量打点记录');
      return;
    }
    const target = batchPeriod || Number(powerStore?.current_period || 0) + 1;
    Modal.confirm({
      title: `确认批量打点到 Period ${target}?`,
      content: `共 ${updates.length} 条用户算力更新`,
      onOk: () => doAction('批量打点', () => stageBatch({ target_period: target, updates })),
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
              <Col xs={12} md={4}><Statistic title="下一打点" value={`P${formatNumber(stageTargetPeriod)}`} /></Col>
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
                      <Form layout="vertical" style={{ marginTop: 16 }}>
                        <Form.Item label="Epoch 间隔秒数">
                          <Space.Compact style={{ width: '100%' }}>
                            <InputNumber
                              value={epochIntervalSecsVal ?? undefined}
                              onChange={(value) => setEpochIntervalSecsVal(value ?? null)}
                              min={1}
                              precision={0}
                              addonAfter="秒"
                              placeholder={`当前 ${formatNumber(chainCfg.epoch_interval_secs || 0)}`}
                              style={{ width: '100%' }}
                            />
                            <Button loading={submitting} onClick={handleSetEpochInterval}>修改</Button>
                          </Space.Compact>
                        </Form.Item>
                      </Form>
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
                  <Col xs={24} xl={9}>
                    <Card title="当前参数" size="small">
                      <Descriptions bordered column={1} size="small">
                        <Descriptions.Item label="epoch_interval_secs">{formatNumber(chainCfg.epoch_interval_secs || 0)}</Descriptions.Item>
                        <Descriptions.Item label="octas_per_million_power">{formatNumber(stk.octas_per_million_power || 0)}</Descriptions.Item>
                        <Descriptions.Item label="min_active_power">{formatNumber(stk.min_active_power || 0)}</Descriptions.Item>
                        <Descriptions.Item label="force_exit_power_bps">{formatNumber(stk.force_exit_power_bps || 0)} ({formatBps(stk.force_exit_power_bps || 0)})</Descriptions.Item>
                        <Descriptions.Item label="cooldown_secs">{formatNumber(stk.cooldown_secs || 0)}</Descriptions.Item>
                        <Descriptions.Item label="min_voting_threshold">{formatNumber(gov.min_voting_threshold || 0)}</Descriptions.Item>
                        <Descriptions.Item label="required_proposer_stake">{formatNumber(gov.required_proposer_stake || 0)}</Descriptions.Item>
                        <Descriptions.Item label="voting_duration_secs">{formatNumber(gov.voting_duration_secs || 0)}</Descriptions.Item>
                      </Descriptions>
                    </Card>
                  </Col>
                  <Col xs={24} xl={15}>
                    <Card title="参数修改" size="small">
                      <Form layout="vertical">
                        <Row gutter={12}>
                          <Col xs={24} md={12}>
                            <Form.Item label="经济参数 / octas_per_million_power">
                              <Space.Compact style={{ width: '100%' }}>
                                <InputNumber
                                  value={octasPerMillionPowerVal ?? undefined}
                                  onChange={(value) => setOctasPerMillionPowerVal(value ?? null)}
                                  min={0}
                                  precision={0}
                                  placeholder={`当前 ${formatNumber(stk.octas_per_million_power || 0)}`}
                                  style={{ width: '100%' }}
                                />
                                <Button loading={submitting} onClick={handleSetOctasPerMillionPower}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label="经济参数 / min_active_power">
                              <Space.Compact style={{ width: '100%' }}>
                                <InputNumber
                                  value={minActivePowerVal ?? undefined}
                                  onChange={(value) => setMinActivePowerVal(value ?? null)}
                                  min={1}
                                  precision={0}
                                  placeholder={`当前 ${formatNumber(stk.min_active_power || 0)}`}
                                  style={{ width: '100%' }}
                                />
                                <Button loading={submitting} onClick={handleSetMinActivePower}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label="经济参数 / force_exit_power_bps">
                              <Space.Compact style={{ width: '100%' }}>
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
                                <Button loading={submitting} onClick={handleSetForceExitPowerBps}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label="经济参数 / cooldown_secs">
                              <Space.Compact style={{ width: '100%' }}>
                                <InputNumber
                                  value={cooldownSecsVal ?? undefined}
                                  onChange={(value) => setCooldownSecsVal(value ?? null)}
                                  min={0}
                                  precision={0}
                                  placeholder={`当前 ${formatNumber(stk.cooldown_secs || 0)}`}
                                  style={{ width: '100%' }}
                                />
                                <Button loading={submitting} onClick={handleSetCooldownSecs}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={8}>
                            <Form.Item label="治理参数 / min_voting_threshold">
                              <InputNumber
                                value={minVotingThresholdVal ?? undefined}
                                onChange={(value) => setMinVotingThresholdVal(value ?? null)}
                                min={0}
                                precision={0}
                                placeholder={`当前 ${formatNumber(gov.min_voting_threshold || 0)}`}
                                style={{ width: '100%' }}
                              />
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={8}>
                            <Form.Item label="治理参数 / required_proposer_stake">
                              <InputNumber
                                value={requiredProposerStakeVal ?? undefined}
                                onChange={(value) => setRequiredProposerStakeVal(value ?? null)}
                                min={0}
                                precision={0}
                                placeholder={`当前 ${formatNumber(gov.required_proposer_stake || 0)}`}
                                style={{ width: '100%' }}
                              />
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={8}>
                            <Form.Item label="治理参数 / voting_duration_secs">
                              <InputNumber
                                value={votingDurationVal ?? undefined}
                                onChange={(value) => setVotingDurationVal(value ?? null)}
                                min={1}
                                precision={0}
                                placeholder={`当前 ${formatNumber(gov.voting_duration_secs || 0)}`}
                                style={{ width: '100%' }}
                              />
                            </Form.Item>
                          </Col>
                        </Row>
                        <Button loading={submitting} onClick={handleUpdateGovernanceConfig}>修改治理参数</Button>
                      </Form>
                    </Card>
                  </Col>
                </Row>
              </>
            ),
          },
          {
            key: 'power',
            label: 'PowerStore 管理',
            children: (
              <>
                <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
                  <Col xs={24} xl={8}>
                    <Card title="PowerStore 总览" size="small">
                      <Descriptions bordered size="small" column={1}>
                        <Descriptions.Item label="Operator">{powerStore?.operator ? <AddressTag address={powerStore.operator} /> : '-'}</Descriptions.Item>
                        <Descriptions.Item label="当前 Epoch">{formatNumber(powerStore?.current_epoch || 0)}</Descriptions.Item>
                        <Descriptions.Item label="当前 Period">{formatNumber(powerStore?.current_period || 0)}</Descriptions.Item>
                        <Descriptions.Item label="下一 Epoch Period">{formatNumber(powerStore?.next_epoch_period || 0)}</Descriptions.Item>
                        <Descriptions.Item label="下一打点 Period">{formatNumber(stageTargetPeriod)}</Descriptions.Item>
                        <Descriptions.Item label="周期长度">{formatNumber(powerStore?.power_period_in_epochs || 0)} Epoch</Descriptions.Item>
                        <Descriptions.Item label="Clock 状态">{powerStore?.power_period_clock_initialized ? <Tag color="green">已初始化</Tag> : <Tag color="orange">未初始化</Tag>}</Descriptions.Item>
                        <Descriptions.Item label="Clock 倒计时">{powerStore?.power_period_clock_initialized ? `${formatNumber(powerStore?.power_period_clock_countdown || 0)} Epoch` : '-'}</Descriptions.Item>
                        <Descriptions.Item label="距离下个 Period">{powerStore?.power_period_clock_initialized ? `${formatNumber(powerStore?.epochs_until_next_period || 0)} Epoch` : '-'}</Descriptions.Item>
                        <Descriptions.Item label="保留系数">{formatNumber(powerStore?.retention_bps || 0)} ({formatBps(powerStore?.retention_bps || 0)})</Descriptions.Item>
                        <Descriptions.Item label="每 Period 衰减">{formatNumber(powerStore?.decay_bps || 0)} ({formatBps(powerStore?.decay_bps || 0)})</Descriptions.Item>
                        <Descriptions.Item label="已关注用户">{formatNumber(powerStore?.watched_user_count || 0)}</Descriptions.Item>
                      </Descriptions>
                    </Card>
                  </Col>
                  <Col xs={24} xl={16}>
                    <Card title="PowerStore 操作" size="small">
                      <Form layout="vertical">
                        <Row gutter={12}>
                          <Col xs={24} md={12}>
                            <Form.Item label="周期长度">
                              <Space.Compact style={{ width: '100%' }}>
                                <InputNumber value={periodVal} onChange={(value) => setPeriodVal(value || 1)} min={1} addonAfter="Epochs" style={{ width: '100%' }} />
                                <Button loading={submitting} onClick={() => doAction('修改周期', () => setPeriod({ power_period_in_epochs: periodVal }))}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label="保留系数">
                              <Space.Compact style={{ width: '100%' }}>
                                <InputNumber value={retentionVal} onChange={(value) => setRetentionVal(value || 1)} min={1} max={10000} addonAfter="bps" style={{ width: '100%' }} />
                                <Button loading={submitting} onClick={() => doAction('修改保留系数', () => setRetention({ retention_bps_per_period: retentionVal }))}>修改</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label="Operator">
                              <Space.Compact style={{ width: '100%' }}>
                                <AddressSelect kind="user" value={operatorAddr || undefined} onChange={setOperatorAddr} placeholder="选择新的 operator" style={{ width: '100%' }} />
                                <Button loading={submitting} onClick={handleSetOperator}>设置</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item label={`单用户打点 (P${formatNumber(stageTargetPeriod)})`}>
                              <Space.Compact style={{ width: '100%' }}>
                                <AddressSelect kind="user" value={stageAddr || undefined} onChange={setStageAddr} placeholder="选择用户" style={{ width: '100%' }} />
                                <InputNumber value={stagePower} onChange={(value) => setStagePower(value || 0)} min={0} precision={0} placeholder="power" style={{ width: 130 }} />
                                <Button loading={submitting} onClick={() => doAction('单用户打点', () => stageSingle({ user_address: stageAddr, power: stagePower }))}>打点</Button>
                              </Space.Compact>
                            </Form.Item>
                          </Col>
                          {!powerStore?.power_period_clock_initialized ? (
                            <Col xs={24}>
                              <Alert
                                type="warning"
                                showIcon
                                message="PowerPeriodClock 未初始化"
                                action={<Button size="small" loading={submitting} onClick={() => doAction('初始化 PowerPeriodClock', () => initializePowerPeriodClock())}>初始化</Button>}
                              />
                            </Col>
                          ) : null}
                        </Row>
                      </Form>
                    </Card>
                  </Col>
                </Row>

                <Card title="批量打点" size="small">
                  <Form layout="vertical">
                    <Row gutter={[16, 16]}>
                      <Col xs={24} xl={16}>
                        <Form.Item label="打点记录">
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
                          <Button type="primary" loading={submitting} onClick={handleBatchStage}>提交批量打点</Button>
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
