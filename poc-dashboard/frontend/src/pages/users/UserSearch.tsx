import { useState, useCallback } from 'react';
import { Card, Table, Button, Space, Modal, Input, message, Tag } from 'antd';
import { PlusOutlined, DeleteOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { getWatchedUsers, addToWatchlist, removeFromWatchlist } from '../../services/watchlist';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressTag from '../../components/AddressTag';
import { formatNumber, formatRewardAmount } from '../../utils/format';

export default function UserSearch() {
  const navigate = useNavigate();
  const fetchUsers = useCallback(() => getWatchedUsers(), []);
  const { data, loading, refresh } = usePolling(fetchUsers, 0);
  useEventRefresh(['epoch_changed', 'power_period_advanced', 'history_sampled'], refresh);

  const [showAdd, setShowAdd] = useState(false);
  const [newAddr, setNewAddr] = useState('');
  const [newLabel, setNewLabel] = useState('');

  const handleAdd = async () => {
    if (!newAddr.startsWith('0x') || newAddr.length < 4) {
      message.warning('请输入有效的 0x 地址');
      return;
    }
    try {
      await addToWatchlist({ kind: 'user', address: newAddr, label: newLabel || undefined });
      message.success('用户添加成功');
      setNewAddr('');
      setNewLabel('');
      setShowAdd(false);
      refresh();
    } catch {}
  };

  const handleRemove = async (address: string) => {
    Modal.confirm({
      title: '确认移除该用户?',
      content: address,
      onOk: async () => {
        await removeFromWatchlist('user', address);
        message.success('已移除');
        refresh();
      },
    });
  };

  const columns = [
    { title: '地址', dataIndex: 'address', render: (v: string) => <AddressTag address={v} /> },
    { title: '备注', dataIndex: 'label', render: (v: string) => v || <span style={{ color: '#ccc' }}>-</span> },
    { title: 'TOPO 余额', dataIndex: 'balance_topo', render: (v: number) => v?.toFixed(2) ?? '-' },
    { title: '已提交算力', dataIndex: 'committed_power', render: formatNumber },
    { title: '有效算力', dataIndex: 'effective_power', render: (v: number) => formatNumber(v || 0) },
    { title: '保证金 TOPO', dataIndex: 'deposit_topo', render: (v: number) => v?.toFixed(2) ?? '-' },
    { title: '预计奖励', render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_reward_octas || 0) },
    { title: '预计手续费', render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_fee_octas || 0) },
    { title: '预计入账', render: (_: any, r: any) => formatRewardAmount(r.rewards?.estimated_epoch_total_octas || 0) },
    { title: '委托', dataIndex: 'delegated_to', render: (v: string) => v && v !== '0x0' ? <AddressTag address={v} /> : <Tag>未委托</Tag> },
    {
      title: '操作', render: (_: any, r: any) => (
        <Space>
          <Button size="small" type="primary" onClick={() => navigate(`/users/${r.address}`)}>详情</Button>
          <Button size="small" danger icon={<DeleteOutlined />} onClick={() => handleRemove(r.address)} />
        </Space>
      ),
    },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setShowAdd(true)}>添加用户</Button>
      </Space>

      <Table
        dataSource={data?.users || []}
        columns={columns}
        rowKey="address"
        loading={loading}
        size="middle"
        onRow={(r: any) => ({ onClick: () => navigate(`/users/${r.address}`), style: { cursor: 'pointer' } })}
      />

      <Modal title="添加用户" open={showAdd} onOk={handleAdd} onCancel={() => setShowAdd(false)} okText="添加">
        <Space direction="vertical" style={{ width: '100%', marginTop: 16 }}>
          <Input placeholder="用户地址 0x..." value={newAddr} onChange={(e) => setNewAddr(e.target.value)} />
          <Input placeholder="备注（可选）" value={newLabel} onChange={(e) => setNewLabel(e.target.value)} />
        </Space>
      </Modal>
    </div>
  );
}
