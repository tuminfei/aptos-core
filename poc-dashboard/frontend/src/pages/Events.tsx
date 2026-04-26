import { useState, useCallback } from 'react';
import { Table, Select, Button, Space, Tag } from 'antd';
import { ReloadOutlined } from '@ant-design/icons';
import api from '../services/api';
import { usePolling } from '../hooks/usePolling';

const MODULES = ['', 'poc_power_store', 'staking_registry', 'stake', 'poc_contribution', 'poc_registry'];

export default function Events() {
  const [module, setModule] = useState('');
  const fetchEvents = useCallback(() => api.get('/events', { params: { module: module || undefined, limit: 50 } }).then((r) => r.data), [module]);
  const { data, loading, refresh } = usePolling(fetchEvents, 30000, [module]);

  const columns = [
    { title: 'Version', dataIndex: 'version', width: 100 },
    { title: '模块', dataIndex: 'module', render: (v: string) => v ? <Tag>{v}</Tag> : '-' },
    { title: '事件类型', dataIndex: 'type', ellipsis: true },
    {
      title: '数据摘要', dataIndex: 'data', render: (v: any) => (
        <span style={{ fontSize: 12, color: '#666' }}>{JSON.stringify(v).slice(0, 80)}...</span>
      ),
    },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <span>模块筛选:</span>
        <Select value={module} onChange={setModule} style={{ width: 200 }}
          options={MODULES.map((m) => ({ value: m, label: m || '全部' }))}
        />
        <Button icon={<ReloadOutlined />} onClick={refresh}>刷新</Button>
      </Space>
      <Table
        dataSource={data?.events || []}
        columns={columns}
        rowKey={(r: any) => `${r.version}-${r.sequence_number}`}
        loading={loading}
        size="small"
        expandable={{
          expandedRowRender: (r: any) => <pre style={{ fontSize: 11, maxHeight: 200, overflow: 'auto' }}>{JSON.stringify(r.data, null, 2)}</pre>,
        }}
      />
    </div>
  );
}
