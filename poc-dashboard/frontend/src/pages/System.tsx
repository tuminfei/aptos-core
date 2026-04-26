import { useCallback, useState } from 'react';
import { Card, Row, Col, Statistic, Button, InputNumber, Space, Modal, Descriptions, message } from 'antd';
import { getChainInfo, getGovernanceConfig, forceEndEpoch, mintTopo } from '../services/governance';
import { setPeriod } from '../services/power';
import { usePolling } from '../hooks/usePolling';
import AddressSelect from '../components/AddressSelect';
import { formatNumber, formatTimestamp, topoToOctas } from '../utils/format';

export default function System() {
  const fetchChain = useCallback(() => getChainInfo(), []);
  const fetchConfig = useCallback(() => getGovernanceConfig(), []);
  const { data: chain, refresh: refreshChain } = usePolling(fetchChain, 10000);
  const { data: config } = usePolling(fetchConfig, 30000);

  const [mintAddr, setMintAddr] = useState('');
  const [mintAmount, setMintAmount] = useState<number>(0);
  const [periodVal, setPeriodVal] = useState<number>(5);
  const [submitting, setSubmitting] = useState(false);

  const doAction = async (name: string, fn: () => Promise<any>) => {
    setSubmitting(true);
    try {
      await fn();
      message.success(`${name}成功`);
      refreshChain();
    } catch {}
    setSubmitting(false);
  };

  const gov = config?.governance || {};
  const stk = config?.staking || {};
  const pwr = config?.power || {};

  return (
    <div>
      <Card title="链信息" style={{ marginBottom: 16 }}>
        <Row gutter={16}>
          <Col span={4}><Statistic title="Chain ID" value={chain?.chain_id || 0} /></Col>
          <Col span={4}><Statistic title="Epoch" value={chain?.epoch || 0} /></Col>
          <Col span={4}><Statistic title="版本" value={formatNumber(chain?.ledger_version || 0)} /></Col>
          <Col span={4}><Statistic title="区块高度" value={formatNumber(chain?.block_height || 0)} /></Col>
          <Col span={8}><Statistic title="时间" value={formatTimestamp(chain?.ledger_timestamp || '')} /></Col>
        </Row>
      </Card>

      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={8}>
          <Card title="强制结束 Epoch" size="small">
            <Button type="primary" danger loading={submitting} onClick={() => Modal.confirm({ title: '确认强制结束当前Epoch?', onOk: () => doAction('强制结束Epoch', forceEndEpoch) })}>
              强制结束Epoch
            </Button>
          </Card>
        </Col>
        <Col span={8}>
          <Card title="TOPO 铸造" size="small">
            <Space direction="vertical">
              <AddressSelect kind="user" value={mintAddr || undefined} onChange={setMintAddr} placeholder="选择接收用户" style={{ width: '100%' }} />
              <Space>
                <InputNumber value={mintAmount} onChange={(v) => setMintAmount(v || 0)} addonAfter="TOPO" min={0} />
                <Button loading={submitting} onClick={() => doAction('铸造', () => mintTopo({ recipient: mintAddr, amount: topoToOctas(mintAmount) }))}>铸造</Button>
              </Space>
            </Space>
          </Card>
        </Col>
        <Col span={8}>
          <Card title="算力周期配置" size="small">
            <Space>
              <InputNumber value={periodVal} onChange={(v) => setPeriodVal(v || 1)} min={1} addonAfter="Epochs" />
              <Button loading={submitting} onClick={() => doAction('修改周期', () => setPeriod({ power_period_in_epochs: periodVal }))}>修改</Button>
            </Space>
          </Card>
        </Col>
      </Row>

      <Card title="系统参数（只读）">
        <Descriptions bordered column={2} size="small">
          <Descriptions.Item label="octas_per_power">{formatNumber(stk.octas_per_power || 0)}</Descriptions.Item>
          <Descriptions.Item label="cooldown_secs">{formatNumber(stk.cooldown_secs || 0)}</Descriptions.Item>
          <Descriptions.Item label="retention_bps">{pwr.retention_bps || 0} ({((pwr.retention_bps || 0) / 100).toFixed(1)}%)</Descriptions.Item>
          <Descriptions.Item label="power_period_in_epochs">{pwr.power_period_in_epochs || 0}</Descriptions.Item>
          <Descriptions.Item label="min_voting_threshold">{formatNumber(gov.min_voting_threshold || 0)}</Descriptions.Item>
          <Descriptions.Item label="voting_duration_secs">{formatNumber(gov.voting_duration_secs || 0)}</Descriptions.Item>
        </Descriptions>
      </Card>
    </div>
  );
}
