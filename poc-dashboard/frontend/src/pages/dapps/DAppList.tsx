import { useCallback, useState } from 'react';
import { Table, Tag, Button, Space, Modal, Form, Input, InputNumber, Checkbox, Card, Typography, message } from 'antd';
import { ExperimentOutlined, ReloadOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { createDemoDApp, getDApps } from '../../services/dapp';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressTag from '../../components/AddressTag';
import { APP_STATE_LABEL, APP_STATE_COLOR, POC_STATUS_LABEL, POC_STATUS_COLOR } from '../../utils/constants';
import { formatNumber, formatTopo } from '../../utils/format';

const DEFAULT_GAS_MINT = 1_000_000_000_000;

export default function DAppList() {
  const navigate = useNavigate();
  const [form] = Form.useForm();
  const fetchDApps = useCallback(() => getDApps(), []);
  const { data, loading, refresh } = usePolling(fetchDApps, 0);
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);

  useEventRefresh(['dapp_changed', 'dapp_operation', 'dapp_trade', 'dapp_trade_task'], refresh);

  const handleCreate = async () => {
    const values = await form.validateFields();
    setCreating(true);
    try {
      const result = await createDemoDApp(values);
      message.success('Demo DApp 创建成功');
      setOpen(false);
      refresh();
      if (result?.app_admin) {
        navigate(`/dapps/${result.app_admin}`);
      }
    } catch {
      // API interceptor already reports the error.
    } finally {
      setCreating(false);
    }
  };

  const columns = [
    {
      title: 'DApp',
      dataIndex: 'app_admin',
      render: (v: string, r: any) => (
        <Space direction="vertical" size={0}>
          <Space>
            <AddressTag address={v} />
            {r.demo?.module_address && <Tag color="blue">Demo</Tag>}
          </Space>
          {r.label && <Typography.Text type="secondary" style={{ fontSize: 12 }}>{r.label}</Typography.Text>}
        </Space>
      ),
    },
    { title: '状态', dataIndex: 'app_state_code', render: (v: number) => <Tag color={APP_STATE_COLOR[v]}>{APP_STATE_LABEL[v] || '未知'}</Tag> },
    { title: 'POC状态', dataIndex: 'poc_listing_status_code', render: (v: number) => <Tag color={POC_STATUS_COLOR[v]}>{POC_STATUS_LABEL[v] || '未知'}</Tag> },
    { title: '贡献可计入', dataIndex: 'eligible_for_poc', render: (v: boolean) => <Tag color={v ? 'green' : 'default'}>{v ? '是' : '否'}</Tag> },
    { title: '权重', dataIndex: 'effective_weight_pbs', render: (v: number) => v ? `${(v / 100).toFixed(1)}%` : '-' },
    {
      title: 'Demo交易',
      render: (_: any, r: any) => {
        const demo = r.demo || {};
        if (!demo.module_address) return '-';
        return (
          <Space direction="vertical" size={0}>
            <span>交易 {formatNumber(demo.trade_count || 0)}</span>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>售出 {formatNumber(demo.total_equity_sold || 0)}</Typography.Text>
          </Space>
        );
      },
    },
    {
      title: '操作',
      width: 100,
      render: (_: any, r: any) => (
        <Button size="small" onClick={() => navigate(`/dapps/${r.app_admin}`)}>详情</Button>
      ),
    },
  ];

  return (
    <div>
      <Card
        title="DApp 管理"
        extra={(
          <Space>
            <Button icon={<ReloadOutlined />} onClick={refresh}>刷新</Button>
            <Button type="primary" icon={<ExperimentOutlined />} onClick={() => setOpen(true)}>生成测试 Demo DApp</Button>
          </Space>
        )}
      >
        <Table
          dataSource={data?.apps || []}
          columns={columns}
          rowKey="app_admin"
          loading={loading}
          size="middle"
          scroll={{ x: 1000 }}
        />
      </Card>

      <Modal
        title="生成测试 Demo DApp"
        open={open}
        onOk={handleCreate}
        onCancel={() => setOpen(false)}
        confirmLoading={creating}
        width={720}
        okText="部署并注册"
      >
        <Form
          form={form}
          layout="vertical"
          initialValues={{
            label: `demo-dapp-${Date.now().toString().slice(-5)}`,
            metadata_uri: 'https://demo.topo.local/poc',
            initial_supply: 1_000_000,
            price_per_equity: 1,
            auto_whitelist: true,
            gas_mint_octas: DEFAULT_GAS_MINT,
            max_gas: 400_000,
            gas_unit_price: 100,
          }}
        >
          <Form.Item name="label" label="DApp 管理员标签" rules={[{ required: true }]}>
            <Input placeholder="demo-dapp-a" />
          </Form.Item>
          <Form.Item name="metadata_uri" label="metadata_uri" rules={[{ required: true }]}>
            <Input placeholder="https://..." />
          </Form.Item>
          <Space style={{ width: '100%' }} align="start">
            <Form.Item name="initial_supply" label="初始 Equity 库存" rules={[{ required: true }]} style={{ width: 200 }}>
              <InputNumber min={1} precision={0} style={{ width: '100%' }} />
            </Form.Item>
            <Form.Item name="price_per_equity" label="每份 Equity 价格 octas" rules={[{ required: true }]} style={{ width: 220 }}>
              <InputNumber min={1} precision={0} style={{ width: '100%' }} />
            </Form.Item>
            <Form.Item name="gas_mint_octas" label="管理员 Gas 铸币" style={{ width: 220 }}>
              <InputNumber min={0} precision={0} style={{ width: '100%' }} addonAfter="octas" />
            </Form.Item>
          </Space>
          <Space style={{ width: '100%' }} align="start">
            <Form.Item name="max_gas" label="max_gas" style={{ width: 200 }}>
              <InputNumber min={1} precision={0} style={{ width: '100%' }} />
            </Form.Item>
            <Form.Item name="gas_unit_price" label="gas_unit_price" style={{ width: 200 }}>
              <InputNumber min={1} precision={0} style={{ width: '100%' }} />
            </Form.Item>
            <Form.Item name="auto_whitelist" valuePropName="checked" label=" ">
              <Checkbox>注册后自动加入 POC 白名单</Checkbox>
            </Form.Item>
          </Space>
          <Typography.Text type="secondary">
            部署包会引用正式 0x1::poc_registry 和 0x1::poc_contribution。默认管理员 Gas 铸币约 {formatTopo(DEFAULT_GAS_MINT)} TOPO。
          </Typography.Text>
        </Form>
      </Modal>
    </div>
  );
}
