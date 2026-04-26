import { useCallback, useState } from 'react';
import { Table, Select, Button, Space, Modal, Input, message, Tag } from 'antd';
import { PlusOutlined, DeleteOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { getWatchedValidators, addToWatchlist, removeFromWatchlist } from '../../services/watchlist';
import { usePolling } from '../../hooks/usePolling';
import AddressTag from '../../components/AddressTag';
import StatusBadge from '../../components/StatusBadge';
import { formatNumber, formatRewardAmount } from '../../utils/format';

export default function ValidatorList() {
  const navigate = useNavigate();
  const fetchValidators = useCallback(() => getWatchedValidators(), []);
  const { data, loading, refresh } = usePolling(fetchValidators, 15000);

  const [showAdd, setShowAdd] = useState(false);
  const [newAddr, setNewAddr] = useState('');
  const [newLabel, setNewLabel] = useState('');

  const handleAdd = async () => {
    if (!newAddr.startsWith('0x') || newAddr.length < 4) {
      message.warning('请输入有效的 0x 地址');
      return;
    }
    try {
      await addToWatchlist({ kind: 'validator', address: newAddr, label: newLabel || undefined });
      message.success('验证者添加成功');
      setNewAddr('');
      setNewLabel('');
      setShowAdd(false);
      refresh();
    } catch {}
  };

  const handleRemove = async (address: string) => {
    Modal.confirm({
      title: '确认从列表移除该验证者?',
      content: address,
      onOk: async () => {
        await removeFromWatchlist('validator', address);
        message.success('已移除');
        refresh();
      },
    });
  };

  const columns = [
    { title: '地址', dataIndex: 'address', render: (v: string) => <AddressTag address={v} /> },
    { title: '备注', dataIndex: 'label', render: (v: string) => v || <span style={{ color: '#ccc' }}>-</span> },
    { title: '状态', dataIndex: 'status', render: (v: string) => <StatusBadge status={v} /> },
    { title: '投票权', dataIndex: 'voting_power', render: formatNumber },
    { title: '委托人数', dataIndex: 'delegator_count', render: (v: number) => formatNumber(v || 0) },
    { title: '预计奖励', render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_reward_octas || 0) },
    { title: '预计手续费', render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_fee_octas || 0) },
    {
      title: '预计总入账',
      render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_total_octas || 0),
    },
    {
      title: '来源', dataIndex: 'in_watchlist', render: (v: boolean) => (
        <Tag color={v ? 'blue' : 'default'}>{v ? '已添加' : '链上发现'}</Tag>
      ),
    },
    {
      title: '操作', render: (_: any, r: any) => (
        <Space>
          <Button size="small" type="primary" onClick={(e) => { e.stopPropagation(); navigate(`/validators/${r.address}`); }}>详情</Button>
          {r.in_watchlist && (
            <Button size="small" danger icon={<DeleteOutlined />} onClick={(e) => { e.stopPropagation(); handleRemove(r.address); }} />
          )}
        </Space>
      ),
    },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setShowAdd(true)}>添加验证者</Button>
        <Button onClick={() => navigate('/validators/add')}>添加验证者向导</Button>
      </Space>

      <Table
        dataSource={data?.validators || []}
        columns={columns}
        rowKey="address"
        loading={loading}
        size="middle"
        onRow={(r: any) => ({ onClick: () => navigate(`/validators/${r.address}`), style: { cursor: 'pointer' } })}
      />

      <Modal title="添加验证者到列表" open={showAdd} onOk={handleAdd} onCancel={() => setShowAdd(false)} okText="添加">
        <Space direction="vertical" style={{ width: '100%', marginTop: 16 }}>
          <Input placeholder="验证者地址 0x..." value={newAddr} onChange={(e) => setNewAddr(e.target.value)} />
          <Input placeholder="备注（可选）" value={newLabel} onChange={(e) => setNewLabel(e.target.value)} />
        </Space>
      </Modal>
    </div>
  );
}
