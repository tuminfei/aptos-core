import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Row, Col, Card, Statistic, Button, InputNumber, Space, Modal, message, Tag } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getUser, getPowerHistory } from '../../services/user';
import { mintTopo } from '../../services/governance';
import { stageSingle } from '../../services/power';
import { deposit, delegate, undelegate, withdraw } from '../../services/staking';
import { usePolling } from '../../hooks/usePolling';
import AddressTag from '../../components/AddressTag';
import AddressSelect from '../../components/AddressSelect';
import { formatNumber, formatRewardAmount, formatRewardRate, formatTopo, topoToOctas } from '../../utils/format';

export default function UserDetail() {
  const { address } = useParams<{ address: string }>();
  const fetchUser = useCallback(() => getUser(address!), [address]);
  const fetchHistory = useCallback(() => getPowerHistory(address!), [address]);
  const { data, loading, refresh } = usePolling(fetchUser, 15000, [address]);
  const { data: historyData } = usePolling(fetchHistory, 30000, [address]);

  const [mintAmount, setMintAmount] = useState<number>(0);
  const [powerVal, setPowerVal] = useState<number>(0);
  const [depositAmount, setDepositAmount] = useState<number>(0);
  const [delegateTo, setDelegateTo] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const u = data || {};
  const balance = u.balance || {};
  const power = u.power || {};
  const staking = u.staking || {};
  const rewards = u.rewards || {};
  const rewardRate = rewards.reward_rate || {};
  const history = historyData?.history || [];

  const chartOption = {
    xAxis: { type: 'category' as const, data: history.map((h: any) => `P${h.period}`) },
    yAxis: { type: 'value' as const },
    series: [{ type: 'line', data: history.map((h: any) => h.power), smooth: true, areaStyle: {} }],
    tooltip: { trigger: 'axis' as const },
  };

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
        <Space style={{ marginTop: 12 }}>
          <Tag color={rewards.auto_compound ? 'green' : 'default'}>{rewards.auto_compound ? '奖励自动复投到保证金' : '奖励方式未知'}</Tag>
          {rewards.is_validator_owner && <Tag color="blue">包含验证者佣金 {formatRewardAmount(rewards.estimated_owner_commission_octas || 0)}</Tag>}
          {rewards.delegated_to && rewards.delegated_to !== '0x0' ? <span style={{ color: '#666' }}>委托给 <AddressTag address={rewards.delegated_to} /></span> : <Tag>未委托</Tag>}
        </Space>
      </Card>

      <Card title="算力历史" style={{ marginBottom: 16 }}>
        <ReactECharts option={chartOption} style={{ height: 250 }} />
      </Card>

      <Card title="操作区">
        <Row gutter={[16, 16]}>
          <Col span={12}>
            <Card size="small" title="铸造 TOPO">
              <Space>
                <InputNumber value={mintAmount} onChange={(v) => setMintAmount(v || 0)} addonAfter="TOPO" min={0} />
                <Button loading={submitting} onClick={() => doAction('铸造', () => mintTopo({ recipient: address!, amount: topoToOctas(mintAmount) }))}>铸造</Button>
              </Space>
            </Card>
          </Col>
          <Col span={12}>
            <Card size="small" title="设置算力">
              <Space>
                <InputNumber value={powerVal} onChange={(v) => setPowerVal(v || 0)} min={0} />
                <Button loading={submitting} onClick={() => doAction('设置算力', () => stageSingle({ user_address: address!, power: powerVal }))}>设置</Button>
              </Space>
            </Card>
          </Col>
          <Col span={12}>
            <Card size="small" title="保证金">
              <Space>
                <InputNumber value={depositAmount} onChange={(v) => setDepositAmount(v || 0)} addonAfter="TOPO" min={0} />
                <Button loading={submitting} onClick={() => doAction('保证金', () => deposit({ user_address: address!, amount: topoToOctas(depositAmount) }))}>存入保证金</Button>
              </Space>
            </Card>
          </Col>
          <Col span={12}>
            <Card size="small" title="委托给验证者">
              <Space>
                <AddressSelect kind="validator" value={delegateTo} onChange={setDelegateTo} style={{ width: 300 }} />
                <Button loading={submitting} onClick={() => doAction('委托', () => delegate({ user_address: address!, validator_address: delegateTo }))}>委托</Button>
              </Space>
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
