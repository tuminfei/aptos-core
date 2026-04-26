import { useState, useCallback } from 'react';
import { Table, Select, Space, Tag } from 'antd';
import api from '../services/api';
import { usePolling } from '../hooks/usePolling';
import AddressTag from '../components/AddressTag';
import { ACTION_LABELS } from '../utils/constants';

const ACTIONS = ['', 'stage_power', 'mint_topo', 'deposit', 'delegate', 'undelegate', 'withdraw', 'force_end_epoch', 'join_validator_set', 'leave_validator_set', 'whitelist_app', 'suspend_app', 'set_app_weight', 'register_validator', 'set_power_period', 'stage_batch_power'];

export default function Logs() {
  const [action, setAction] = useState('');
  const [status, setStatus] = useState('');
  const [page, setPage] = useState(1);

  const fetchLogs = useCallback(
    () => api.get('/logs', { params: { action: action || undefined, status: status || undefined, page, page_size: 20 } }).then((r) => r.data),
    [action, status, page],
  );
  const { data, loading } = usePolling(fetchLogs, 30000, [action, status, page]);

  const columns = [
    { title: '时间', dataIndex: 'created_at', width: 180 },
    { title: '操作', dataIndex: 'action', render: (v: string) => <Tag>{ACTION_LABELS[v] || v}</Tag> },
    { title: '目标', dataIndex: 'target', render: (v: string) => v ? <AddressTag address={v} /> : '-' },
    { title: '状态', dataIndex: 'status', render: (v: string) => <Tag color={v === 'success' ? 'green' : 'red'}>{v === 'success' ? '成功' : '失败'}</Tag> },
    { title: 'TX', dataIndex: 'tx_hash', render: (v: string) => v ? <span style={{ fontSize: 11, fontFamily: 'monospace' }}>{v.slice(0, 12)}...</span> : '-' },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <span>操作筛选:</span>
        <Select value={action} onChange={(v) => { setAction(v); setPage(1); }} style={{ width: 180 }}
          options={ACTIONS.map((a) => ({ value: a, label: a ? (ACTION_LABELS[a] || a) : '全部' }))}
        />
        <span>状态:</span>
        <Select value={status} onChange={(v) => { setStatus(v); setPage(1); }} style={{ width: 120 }}
          options={[{ value: '', label: '全部' }, { value: 'success', label: '成功' }, { value: 'failed', label: '失败' }]}
        />
      </Space>
      <Table
        dataSource={data?.logs || []}
        columns={columns}
        rowKey="id"
        loading={loading}
        size="small"
        pagination={{ current: page, total: data?.total || 0, pageSize: 20, onChange: setPage }}
        expandable={{
          expandedRowRender: (r: any) => (
            <div style={{ fontSize: 12 }}>
              {r.params && <div>参数: <pre>{JSON.stringify(r.params, null, 2)}</pre></div>}
              {r.error && <div style={{ color: 'red' }}>错误: {r.error}</div>}
            </div>
          ),
        }}
      />
    </div>
  );
}
