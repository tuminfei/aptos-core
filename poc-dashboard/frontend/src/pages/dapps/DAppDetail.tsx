import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Card, Descriptions, Button, Space, InputNumber, Modal, Tag, message } from 'antd';
import { getDApp, whitelistApp, suspendApp, setWeight } from '../../services/dapp';
import { usePolling } from '../../hooks/usePolling';
import AddressTag from '../../components/AddressTag';
import { APP_STATE_LABEL, APP_STATE_COLOR, POC_STATUS_LABEL, POC_STATUS_COLOR } from '../../utils/constants';

export default function DAppDetail() {
  const { admin } = useParams<{ admin: string }>();
  const fetchDApp = useCallback(() => getDApp(admin!), [admin]);
  const { data, loading, refresh } = usePolling(fetchDApp, 15000, [admin]);
  const [weightVal, setWeightVal] = useState<number>(0);
  const [showWeight, setShowWeight] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const d = data || {};

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
      <Card loading={loading} style={{ marginBottom: 16 }}>
        <Descriptions title={<Space>DApp <AddressTag address={admin || ''} /></Space>} bordered column={2}>
          <Descriptions.Item label="应用状态"><Tag color={APP_STATE_COLOR[d.app_state_code]}>{APP_STATE_LABEL[d.app_state_code]}</Tag></Descriptions.Item>
          <Descriptions.Item label="POC状态"><Tag color={POC_STATUS_COLOR[d.poc_listing_status_code]}>{POC_STATUS_LABEL[d.poc_listing_status_code]}</Tag></Descriptions.Item>
          <Descriptions.Item label="权重">{d.effective_weight_pbs ? `${(d.effective_weight_pbs / 100).toFixed(1)}%` : '-'}</Descriptions.Item>
        </Descriptions>
      </Card>

      <Card title="操作">
        <Space>
          <Button type="primary" loading={submitting} onClick={() => Modal.confirm({ title: '确认加入白名单?', onOk: () => doAction('白名单', () => whitelistApp({ app_admin: admin! })) })}>加入白名单</Button>
          <Button danger loading={submitting} onClick={() => Modal.confirm({ title: '确认暂停POC资格?', onOk: () => doAction('暂停', () => suspendApp({ app_admin: admin! })) })}>暂停POC</Button>
          <Button onClick={() => setShowWeight(true)}>设置权重</Button>
        </Space>
      </Card>

      <Modal title="设置权重" open={showWeight} onOk={() => doAction('设置权重', () => setWeight({ app_admin: admin!, weight_pbs: weightVal })).then(() => setShowWeight(false))} onCancel={() => setShowWeight(false)} confirmLoading={submitting}>
        <div style={{ marginTop: 16 }}>
          <span>权重 (pbs): </span>
          <InputNumber value={weightVal} onChange={(v) => setWeightVal(v || 0)} min={0} max={10000} style={{ width: 200 }} />
          <span style={{ marginLeft: 8, color: '#999' }}>{(weightVal / 100).toFixed(1)}%</span>
        </div>
      </Modal>
    </div>
  );
}
