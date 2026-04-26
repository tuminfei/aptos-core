import { useCallback } from 'react';
import { Table, Tag, Button, Space } from 'antd';
import { useNavigate } from 'react-router-dom';
import { getDApps } from '../../services/dapp';
import { usePolling } from '../../hooks/usePolling';
import AddressTag from '../../components/AddressTag';
import { APP_STATE_LABEL, APP_STATE_COLOR, POC_STATUS_LABEL, POC_STATUS_COLOR } from '../../utils/constants';

export default function DAppList() {
  const navigate = useNavigate();
  const fetchDApps = useCallback(() => getDApps(), []);
  const { data, loading } = usePolling(fetchDApps, 15000);

  const columns = [
    { title: '管理员', dataIndex: 'app_admin', render: (v: string) => <AddressTag address={v} /> },
    { title: '状态', dataIndex: 'app_state_code', render: (v: number) => <Tag color={APP_STATE_COLOR[v]}>{APP_STATE_LABEL[v]}</Tag> },
    { title: 'POC状态', dataIndex: 'poc_listing_status_code', render: (v: number) => <Tag color={POC_STATUS_COLOR[v]}>{POC_STATUS_LABEL[v]}</Tag> },
    { title: '权重', dataIndex: 'effective_weight_pbs', render: (v: number) => v ? `${(v / 100).toFixed(1)}%` : '-' },
    {
      title: '操作', render: (_: any, r: any) => (
        <Button size="small" onClick={() => navigate(`/dapps/${r.app_admin}`)}>详情</Button>
      ),
    },
  ];

  return (
    <div>
      <Table
        dataSource={data?.apps || []}
        columns={columns}
        rowKey="app_admin"
        loading={loading}
        size="middle"
      />
    </div>
  );
}
