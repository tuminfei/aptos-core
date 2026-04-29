import { useState, useCallback } from 'react';
import { Table, Button, Space, Modal, Input, message, Tag, Radio, Alert, Typography } from 'antd';
import { PlusOutlined, DeleteOutlined, EditOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { getWatchedUsers, addToWatchlist, removeFromWatchlist, generateAccount, updateWatchlistLabel } from '../../services/watchlist';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressTag from '../../components/AddressTag';
import { useAddressBook } from '../../contexts/AddressBookContext';
import { formatNumber, formatRewardAmount } from '../../utils/format';

const { Text } = Typography;

export default function UserSearch() {
  const navigate = useNavigate();
  const { refresh: refreshAddressBook } = useAddressBook();
  const fetchUsers = useCallback(() => getWatchedUsers(), []);
  const { data, loading, refresh } = usePolling(fetchUsers, 0);
  useEventRefresh(['epoch_changed', 'power_period_advanced', 'history_sampled', 'address_book_changed'], refresh);

  const [showAdd, setShowAdd] = useState(false);
  const [addMode, setAddMode] = useState<'generate' | 'existing'>('generate');
  const [newAddr, setNewAddr] = useState('');
  const [newLabel, setNewLabel] = useState('');
  const [generated, setGenerated] = useState<any>(null);
  const [creating, setCreating] = useState(false);

  const handleAdd = async () => {
    if (addMode === 'existing' && (!newAddr.startsWith('0x') || newAddr.length < 4)) {
      message.warning('请输入有效的 0x 地址');
      return;
    }
    setCreating(true);
    try {
      if (addMode === 'generate') {
        const account = await generateAccount({ kind: 'user', label: newLabel || undefined });
        setGenerated(account);
        setNewAddr(account.address);
        message.success('用户账户已生成并托管私钥');
      } else {
        await addToWatchlist({ kind: 'user', address: newAddr, label: newLabel || undefined });
        message.success('用户添加成功');
        closeAddModal();
      }
      refresh();
      refreshAddressBook();
    } catch {}
    setCreating(false);
  };

  const closeAddModal = () => {
    setNewAddr('');
    setNewLabel('');
    setGenerated(null);
    setAddMode('generate');
    setCreating(false);
    setShowAdd(false);
  };

  const handleRemove = async (address: string) => {
    Modal.confirm({
      title: '确认移除该用户?',
      content: address,
      onOk: async () => {
        await removeFromWatchlist('user', address);
        message.success('已移除');
        refresh();
        refreshAddressBook();
      },
    });
  };

  const handleRename = (row: any) => {
    const currentName = row.display_name || row.label || '';
    let nextName = currentName;
    Modal.confirm({
      title: '修改用户名',
      content: (
        <Input
          defaultValue={currentName}
          placeholder={row.is_validator_user && !row.in_user_watchlist ? '验证者名' : '用户名'}
          onChange={(event) => { nextName = event.target.value; }}
        />
      ),
      okText: '保存',
      cancelText: '取消',
      onOk: async () => {
        const kind = row.in_user_watchlist || !row.is_validator_user ? 'user' : 'validator';
        await updateWatchlistLabel(kind, row.address, nextName.trim());
        message.success('名称已更新');
        refresh();
        refreshAddressBook();
      },
    });
  };

  const columns = [
    {
      title: '用户名',
      dataIndex: 'display_name',
      render: (v: string, r: any) => (
        <Space direction="vertical" size={2}>
          <AddressTag address={r.address} name={v || r.label} showAddress />
          <Space size={4}>
            {r.is_validator_user ? <Tag color="blue">验证者</Tag> : null}
            <Button
              size="small"
              type="text"
              icon={<EditOutlined />}
              onClick={(event) => {
                event.stopPropagation();
                handleRename(r);
              }}
            />
          </Space>
        </Space>
      ),
    },
    { title: 'TOPO 余额', dataIndex: 'balance_topo', render: (v: number) => v?.toFixed(2) ?? '-' },
    { title: '原始算力', dataIndex: 'raw_power', render: (v: number) => formatNumber(v || 0) },
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
          {r.in_user_watchlist ? (
            <Button size="small" danger icon={<DeleteOutlined />} onClick={() => handleRemove(r.address)} />
          ) : null}
        </Space>
      ),
    },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setShowAdd(true)}>新增普通用户</Button>
      </Space>

      <Table
        dataSource={data?.users || []}
        columns={columns}
        rowKey="address"
        loading={loading}
        size="middle"
        onRow={(r: any) => ({ onClick: () => navigate(`/users/${r.address}`), style: { cursor: 'pointer' } })}
      />

      <Modal
        title="新增普通用户"
        open={showAdd}
        onOk={generated ? closeAddModal : handleAdd}
        onCancel={closeAddModal}
        okText={generated ? '完成' : (addMode === 'generate' ? '生成用户' : '添加')}
        confirmLoading={creating}
      >
        <Space direction="vertical" style={{ width: '100%', marginTop: 16 }}>
          <Radio.Group
            value={addMode}
            onChange={(e) => {
              setAddMode(e.target.value as 'generate' | 'existing');
              setGenerated(null);
              setNewAddr('');
            }}
            optionType="button"
            buttonStyle="solid"
          >
            <Radio.Button value="generate">生成新账户</Radio.Button>
            <Radio.Button value="existing">添加已有地址</Radio.Button>
          </Radio.Group>
          <Input placeholder="用户名（可选）" value={newLabel} onChange={(e) => setNewLabel(e.target.value)} />
          {addMode === 'existing' && (
            <Input placeholder="用户地址 0x..." value={newAddr} onChange={(e) => setNewAddr(e.target.value)} />
          )}
          {addMode === 'generate' && !generated && (
            <Alert
              type="info"
              showIcon
              message="系统会直接生成 Ed25519 私钥和账户地址，并把私钥托管到本地数据库。"
            />
          )}
          {generated && (
            <Alert
              type="success"
              showIcon
              message="账户已生成"
              description={(
                <Space direction="vertical" style={{ width: '100%' }}>
                  <span>地址：<AddressTag address={generated.address} short={false} /></span>
                  <Text copyable={{ text: generated.public_key }} style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                    公钥：{generated.public_key}
                  </Text>
                  <Text copyable={{ text: generated.private_key }} style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                    私钥：{generated.private_key}
                  </Text>
                </Space>
              )}
            />
          )}
        </Space>
      </Modal>
    </div>
  );
}
