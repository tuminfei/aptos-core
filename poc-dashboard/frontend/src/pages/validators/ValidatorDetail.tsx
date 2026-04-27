import { useCallback, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { Card, Descriptions, Table, Button, Space, InputNumber, Modal, message, Row, Col, Statistic, Tag } from 'antd';
import { getValidator, stagePower, joinValidatorSet, leaveValidatorSet } from '../../services/validator';
import { usePolling } from '../../hooks/usePolling';
import AddressTag from '../../components/AddressTag';
import StatusBadge from '../../components/StatusBadge';
import AmountDisplay from '../../components/AmountDisplay';
import { formatNumber, formatPercent, formatRewardAmount, formatRewardRate } from '../../utils/format';

export default function ValidatorDetail() {
  const { address } = useParams<{ address: string }>();
  const navigate = useNavigate();
  const fetchDetail = useCallback(() => getValidator(address!), [address]);
  const { data, loading, refresh } = usePolling(fetchDetail, 15000, [address]);
  const [powerVal, setPowerVal] = useState<number>(0);
  const [showPower, setShowPower] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  if (!data && !loading) return <div>验证者不存在</div>;
  const v = data || {};
  const rewards = v.rewards || {};
  const rewardRate = rewards.reward_rate || {};

  const handleStagePower = async () => {
    setSubmitting(true);
    try {
      await stagePower({ user_address: address!, power: powerVal });
      message.success('算力设置成功');
      setShowPower(false);
      refresh();
    } catch { /* error handled by interceptor */ }
    setSubmitting(false);
  };

  const handleJoin = async () => {
    Modal.confirm({
      title: '确认加入验证者集合?',
      onOk: async () => {
        try {
          await joinValidatorSet({ operator_address: v.operator, pool_address: address! });
          message.success('已提交加入请求');
          refresh();
        } catch {}
      },
    });
  };

  const handleLeave = async () => {
    Modal.confirm({
      title: '确认退出验证者集合?',
      onOk: async () => {
        try {
          await leaveValidatorSet({ operator_address: v.operator, pool_address: address! });
          message.success('已提交退出请求');
          refresh();
        } catch {}
      },
    });
  };

  const delegatorColumns = [
    { title: '地址', dataIndex: 'address', render: (v: string) => <AddressTag address={v} /> },
    { title: '保证金 TOPO', dataIndex: 'deposit_topo', render: (v: number) => v?.toFixed(2) },
    { title: 'POC算力', dataIndex: 'poc_power', render: formatNumber },
    { title: '有效算力', dataIndex: 'effective_power', render: formatNumber },
    { title: '预计奖励', dataIndex: 'estimated_epoch_reward_octas', render: (v: number) => formatRewardAmount(v || 0) },
    { title: '预计手续费', dataIndex: 'estimated_epoch_fee_octas', render: (v: number) => formatRewardAmount(v || 0) },
    { title: '预计入账', dataIndex: 'estimated_epoch_total_octas', render: (v: number) => formatRewardAmount(v || 0) },
    { title: '操作', dataIndex: 'address', key: 'action', render: (addr: string) => <Button size="small" onClick={() => navigate(`/users/${addr}`)}>查看用户</Button> },
  ];

  return (
    <div>
      <Card loading={loading} style={{ marginBottom: 16 }}>
        <Descriptions title={<Space>验证者 <AddressTag address={address || ''} short={false} /> <StatusBadge status={v.status || ''} /></Space>} bordered column={2}>
          <Descriptions.Item label="Operator"><AddressTag address={v.operator || ''} /></Descriptions.Item>
          <Descriptions.Item label="Validator Index">{v.validator_index}</Descriptions.Item>
          <Descriptions.Item label="投票权">{formatNumber(v.voting_power || 0)}</Descriptions.Item>
          <Descriptions.Item label="佣金">{formatPercent(v.commission_bps || 0)}</Descriptions.Item>
          <Descriptions.Item label="奖励率">{formatRewardRate(rewardRate)}</Descriptions.Item>
          <Descriptions.Item label="奖励方式">{rewards.auto_compound ? <Tag color="green">自动复投</Tag> : <Tag>未知</Tag>}</Descriptions.Item>
          <Descriptions.Item label="共识公钥" span={2}><span style={{ fontSize: 11, wordBreak: 'break-all' }}>{v.consensus_pubkey}</span></Descriptions.Item>
          <Descriptions.Item label="Active"><AmountDisplay octas={v.stake?.active || 0} /></Descriptions.Item>
          <Descriptions.Item label="Pending Active"><AmountDisplay octas={v.stake?.pending_active || 0} /></Descriptions.Item>
          <Descriptions.Item label="Inactive"><AmountDisplay octas={v.stake?.inactive || 0} /></Descriptions.Item>
          <Descriptions.Item label="Pending Inactive"><AmountDisplay octas={v.stake?.pending_inactive || 0} /></Descriptions.Item>
          <Descriptions.Item label="出块成功">{v.proposals_successful}</Descriptions.Item>
          <Descriptions.Item label="出块失败">{v.proposals_failed}</Descriptions.Item>
        </Descriptions>
      </Card>

      <Card title="质押奖励" loading={loading} style={{ marginBottom: 16 }}>
        <Row gutter={[16, 16]}>
          <Col span={6}><Statistic title="预计本 epoch 奖励" value={formatRewardAmount(rewards.estimated_epoch_reward_octas || 0)} /></Col>
          <Col span={6}><Statistic title="待分配手续费" value={formatRewardAmount(rewards.pending_fee_octas || 0)} /></Col>
          <Col span={6}><Statistic title="预计本 epoch 入账" value={formatRewardAmount(rewards.estimated_epoch_total_octas || 0)} /></Col>
          <Col span={6}><Statistic title="预计验证者佣金" value={formatRewardAmount(rewards.estimated_commission_octas || 0)} /></Col>
        </Row>
      </Card>

      <Card title={`委托者 (${v.pool?.delegators?.length || 0})`} style={{ marginBottom: 16 }}>
        <Table dataSource={v.pool?.delegators || []} columns={delegatorColumns} rowKey="address" size="small" pagination={false} />
      </Card>

      <Card title="验证者操作">
        <Space>
          <Button onClick={() => setShowPower(true)}>修改算力</Button>
          <Button onClick={handleJoin} type="primary">加入验证者集合</Button>
          <Button onClick={handleLeave} danger>退出验证者集合</Button>
        </Space>
      </Card>

      <Modal title="修改算力" open={showPower} onOk={handleStagePower} onCancel={() => setShowPower(false)} confirmLoading={submitting}>
        <div style={{ marginTop: 16 }}>
          <span>新算力: </span>
          <InputNumber value={powerVal} onChange={(v) => setPowerVal(v || 0)} min={0} style={{ width: 200 }} />
        </div>
      </Modal>
    </div>
  );
}
