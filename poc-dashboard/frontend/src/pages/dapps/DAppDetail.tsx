import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import {
  Button,
  Card,
  Col,
  Descriptions,
  Form,
  Input,
  InputNumber,
  Modal,
  Row,
  Select,
  Space,
  Statistic,
  Table,
  Tabs,
  Tag,
  Typography,
  message,
} from 'antd';
import {
  PauseCircleOutlined,
  PlayCircleOutlined,
  StopOutlined,
  SyncOutlined,
  ThunderboltOutlined,
  InfoCircleOutlined,
} from '@ant-design/icons';
import {
  buyDemoEquity,
  getContributionEvents,
  getDApp,
  mintDemoEquity,
  pauseApp,
  registerApp,
  resumeApp,
  setPocStatus,
  setWeight,
  startDemoAutoTrade,
  stopApp,
  stopDemoAutoTrade,
  updateAppAddress,
  updateCustodyAddress,
  updateEquityTokenAddress,
  whitelistApp,
} from '../../services/dapp';
import { usePolling } from '../../hooks/usePolling';
import { useEventRefresh } from '../../hooks/useEventRefresh';
import AddressSelect from '../../components/AddressSelect';
import AddressTag from '../../components/AddressTag';
import { APP_STATE_LABEL, APP_STATE_COLOR, POC_STATUS_LABEL, POC_STATUS_COLOR } from '../../utils/constants';
import { formatNumber, formatTimestamp, formatTopo } from '../../utils/format';

const DEFAULT_BUYER_MINT = 1_000_000_000_000;

function valueFromInfo(info: any, key: string) {
  return info?.[key] ?? info?.[key.replace(/_([a-z])/g, (_, c) => c.toUpperCase())] ?? '-';
}

function splitAddresses(raw: string): string[] {
  return raw
    .split(/[\n,，\s]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

const TILE_COLORS = {
  blue: '#1677ff',
  green: '#52c41a',
  orange: '#faad14',
  red: '#ff4d4f',
  gray: '#8c8c8c',
} as const;

function SummaryTile({
  title,
  value,
  extra,
  tone = 'blue',
}: {
  title: string;
  value: ReactNode;
  extra?: ReactNode;
  tone?: keyof typeof TILE_COLORS;
}) {
  return (
    <div
      style={{
        minHeight: 92,
        border: '1px solid #f0f0f0',
        borderLeft: `4px solid ${TILE_COLORS[tone]}`,
        borderRadius: 8,
        padding: 14,
        background: '#fff',
      }}
    >
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>{title}</Typography.Text>
      <div style={{ marginTop: 8, fontSize: 20, fontWeight: 600, lineHeight: 1.2 }}>{value}</div>
      {extra && <div style={{ marginTop: 8, fontSize: 12, color: '#666' }}>{extra}</div>}
    </div>
  );
}

function ActionPanel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div style={{ border: '1px solid #f0f0f0', borderRadius: 8, padding: 16, height: '100%' }}>
      <Typography.Title level={5} style={{ marginTop: 0, marginBottom: 16 }}>{title}</Typography.Title>
      {children}
    </div>
  );
}

export default function DAppDetail() {
  const { admin } = useParams<{ admin: string }>();
  const fetchDApp = useCallback(() => getDApp(admin!), [admin]);
  const fetchContributions = useCallback(() => getContributionEvents({ app_admin: admin!, limit: 50 }), [admin]);
  const { data, loading, refresh } = usePolling(fetchDApp, 0, [admin]);
  const { data: contributionData, refresh: refreshContributions } = usePolling(fetchContributions, 0, [admin]);
  const [weightForm] = Form.useForm();
  const [pocForm] = Form.useForm();
  const [manualForm] = Form.useForm();
  const [updateForm] = Form.useForm();
  const [mintForm] = Form.useForm();
  const [buyForm] = Form.useForm();
  const [autoForm] = Form.useForm();
  const [submitting, setSubmitting] = useState(false);

  useEventRefresh(
    ['dapp_changed', 'dapp_operation', 'dapp_trade', 'dapp_trade_task'],
    refresh,
    (event) => {
      const eventAdmin = event.app_admin || event.target;
      return !eventAdmin || String(eventAdmin).toLowerCase() === String(admin || '').toLowerCase();
    },
  );
  useEventRefresh(
    ['contribution_event', 'dapp_trade'],
    refreshContributions,
    (event) => {
      const eventAdmin = event.app_admin;
      return !eventAdmin || String(eventAdmin).toLowerCase() === String(admin || '').toLowerCase();
    },
  );

  const d = data || {};
  const info = d.info || {};
  const demo = d.demo || {};
  const autoTrade = d.auto_trade || {};
  const contributionEvents = contributionData?.events || [];
  const totalContributionEquity = contributionData?.total_equity_amount || 0;
  const moduleAddress = demo.module_address || '';
  const appAddress = valueFromInfo(info, 'app_address');
  const equityTokenAddress = valueFromInfo(info, 'equity_token_address');
  const custodyAddress = valueFromInfo(info, 'custody_address');
  const metadataUri = valueFromInfo(info, 'metadata_uri');
  const effectiveWeight = d.effective_weight_pbs ?? 0;
  const weightText = d.effective_weight_pbs === undefined ? '-' : `${(Number(effectiveWeight) / 100).toFixed(2)}%`;
  const canContribute = Boolean(d.eligible_for_poc);

  useEffect(() => {
    if (!data) return;
    pocForm.setFieldsValue({ status: d.poc_listing_status_code || 1 });
    weightForm.setFieldsValue({ weight_pbs: d.effective_weight_pbs ?? 10000 });
  }, [data, d.poc_listing_status_code, d.effective_weight_pbs, pocForm, weightForm]);

  const doAction = async (name: string, fn: () => Promise<any>) => {
    setSubmitting(true);
    try {
      await fn();
      message.success(`${name}成功`);
      refresh();
    } catch {
      // API interceptor already reports the error.
    } finally {
      setSubmitting(false);
    }
  };

  const runWithConfirm = (title: string, fn: () => Promise<any>) => {
    Modal.confirm({ title, onOk: () => fn() });
  };

  const handleRegisterManual = async () => {
    const values = await manualForm.validateFields();
    await doAction('注册 DApp', () => registerApp({ app_admin: admin!, ...values }));
  };

  const handleUpdateAddress = async () => {
    const values = await updateForm.validateFields();
    const payload = { app_admin: admin!, new_address: values.new_address };
    const action = values.target;
    if (action === 'app') return doAction('更新 App 地址', () => updateAppAddress(payload));
    if (action === 'custody') return doAction('更新 Custody 地址', () => updateCustodyAddress(payload));
    return doAction('更新 Equity Token 地址', () => updateEquityTokenAddress(payload));
  };

  const handleMintEquity = async () => {
    const values = await mintForm.validateFields();
    await doAction('铸造 Equity 库存', () => mintDemoEquity({ app_admin: admin!, module_address: moduleAddress, ...values }));
  };

  const handleBuyEquity = async () => {
    const values = await buyForm.validateFields();
    await doAction('发出贡献交易', () => buyDemoEquity({
      app_admin: admin!,
      module_address: moduleAddress,
      auto_create_buyer: !values.buyer_address,
      buyer_address: values.buyer_address || '',
      buyer_label: values.buyer_label || 'demo-buyer',
      equity_amount: values.equity_amount,
      mint_octas: values.mint_octas || 0,
      max_gas: values.max_gas,
      gas_unit_price: values.gas_unit_price,
    }));
  };

  const handleStartAutoTrade = async () => {
    const values = await autoForm.validateFields();
    await doAction('启动定时交易', () => startDemoAutoTrade({
      app_admin: admin!,
      module_address: moduleAddress,
      interval_secs: values.interval_secs,
      tx_per_tick: values.tx_per_tick,
      amount_min: values.amount_min,
      amount_max: values.amount_max,
      max_runs: values.max_runs || 0,
      buyer_addresses: splitAddresses(values.buyer_addresses || ''),
      auto_create_buyers: values.auto_create_buyers || 0,
      mint_octas: values.mint_octas || 0,
      max_gas: values.max_gas,
      gas_unit_price: values.gas_unit_price,
    }));
  };

  const buyAmount = Form.useWatch('equity_amount', buyForm) || 0;
  const price = Number(demo.price_per_equity || 0);
  const payment = Number(buyAmount || 0) * price;
  const addressValue = (value: unknown) => {
    const text = String(value || '');
    if (!text || text === '-') return '-';
    return <AddressTag address={text} />;
  };

  return (
    <div>
      <Card
        loading={loading}
        style={{ marginBottom: 16 }}
        title={(
          <Space direction="vertical" size={2}>
            <Space wrap>
              <span>DApp 详情</span>
              {demo.configured && <Tag color="blue">Demo</Tag>}
              <Tag color={canContribute ? 'green' : 'orange'}>{canContribute ? '贡献可计入' : '贡献暂不计入'}</Tag>
            </Space>
            <AddressTag address={admin || ''} short={false} />
          </Space>
        )}
        extra={<Button icon={<SyncOutlined />} onClick={refresh}>刷新</Button>}
      >
        <Row gutter={[12, 12]}>
          <Col xs={24} md={12} xl={6}>
            <SummaryTile
              title="应用运行状态"
              value={<Tag color={APP_STATE_COLOR[d.app_state_code]}>{APP_STATE_LABEL[d.app_state_code] || '未知'}</Tag>}
              extra="由 DApp 管理员控制"
              tone={d.app_state_code === 1 ? 'green' : d.app_state_code === 2 ? 'orange' : 'gray'}
            />
          </Col>
          <Col xs={24} md={12} xl={6}>
            <SummaryTile
              title="POC 纳入状态"
              value={<Tag color={POC_STATUS_COLOR[d.poc_listing_status_code]}>{POC_STATUS_LABEL[d.poc_listing_status_code] || '未知'}</Tag>}
              extra="由平台管理操作控制"
              tone={d.poc_listing_status_code === 2 ? 'green' : d.poc_listing_status_code === 3 ? 'red' : 'orange'}
            />
          </Col>
          <Col xs={24} md={12} xl={6}>
            <SummaryTile
              title="有效权重"
              value={weightText}
              extra={`${formatNumber(effectiveWeight)} pbs`}
              tone="blue"
            />
          </Col>
          <Col xs={24} md={12} xl={6}>
            <SummaryTile
              title="Contribution 计入"
              value={<Tag color={canContribute ? 'green' : 'default'}>{canContribute ? '已满足' : '未满足'}</Tag>}
              extra="条件: ACTIVE + WHITELISTED"
              tone={canContribute ? 'green' : 'orange'}
            />
          </Col>
        </Row>
      </Card>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} xl={14}>
          <Card size="small" title="链上注册信息">
            <Descriptions bordered size="small" column={{ xs: 1, md: 2 }}>
              <Descriptions.Item label="管理员地址">{addressValue(admin)}</Descriptions.Item>
              <Descriptions.Item label="App 合约地址">{addressValue(appAddress)}</Descriptions.Item>
              <Descriptions.Item label="权益资产地址">{addressValue(equityTokenAddress)}</Descriptions.Item>
              <Descriptions.Item label="库存托管地址">{addressValue(custodyAddress)}</Descriptions.Item>
              <Descriptions.Item label="Metadata URI" span={2}>{String(metadataUri || '-')}</Descriptions.Item>
              <Descriptions.Item label="Demo 模块地址" span={2}>{moduleAddress ? <AddressTag address={moduleAddress} short={false} /> : '-'}</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
        <Col xs={24} xl={10}>
          <Card size="small" title="Demo 运行态">
            <Row gutter={[12, 12]}>
              <Col span={8}><Statistic title="贡献交易" value={formatNumber(demo.trade_count || 0)} /></Col>
              <Col span={8}><Statistic title="累计售出" value={formatNumber(demo.total_equity_sold || 0)} /></Col>
              <Col span={8}><Statistic title="剩余库存" value={formatNumber(demo.custody_inventory || 0)} /></Col>
            </Row>
            <Descriptions size="small" column={1} style={{ marginTop: 12 }}>
              <Descriptions.Item label="每份 Equity 价格">{formatNumber(demo.price_per_equity || 0)} octas</Descriptions.Item>
              <Descriptions.Item label="初始库存">{formatNumber(demo.initial_supply || 0)}</Descriptions.Item>
              <Descriptions.Item label="配置状态"><Tag color={demo.configured ? 'green' : 'default'}>{demo.configured ? '已配置' : '未配置'}</Tag></Descriptions.Item>
              <Descriptions.Item label="定时任务"><Tag color={autoTrade.status === 'running' ? 'green' : 'default'}>{autoTrade.status === 'running' ? '运行中' : '未运行'}</Tag></Descriptions.Item>
              <Descriptions.Item label="任务执行">{formatNumber(autoTrade.run_count || 0)} / {autoTrade.max_runs ? formatNumber(autoTrade.max_runs) : '不限'}</Descriptions.Item>
              <Descriptions.Item label="成功 / 失败">{formatNumber(autoTrade.success_count || 0)} / {formatNumber(autoTrade.failure_count || 0)}</Descriptions.Item>
              <Descriptions.Item label="最近交易">{autoTrade.last_tx_hash ? <AddressTag address={autoTrade.last_tx_hash} /> : '-'}</Descriptions.Item>
              <Descriptions.Item label="已记录贡献事件">{formatNumber(contributionData?.total || 0)} 条 / {formatNumber(totalContributionEquity)} Equity</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
      </Row>

      <Card
        size="small"
        title="贡献事件历史"
        extra={<Typography.Text type="secondary">从交易返回的 ContributionEvent 解析并保存</Typography.Text>}
        style={{ marginBottom: 16 }}
      >
        <Table
          dataSource={contributionEvents}
          rowKey={(row: any) => `${row.tx_hash}:${row.event_index}`}
          size="small"
          pagination={{ pageSize: 10, showSizeChanger: false }}
          scroll={{ x: 900 }}
          columns={[
            { title: '时间', dataIndex: 'created_at', width: 170, render: (v: string) => formatTimestamp(v) },
            { title: '用户', dataIndex: 'contributor', width: 180, render: (v: string) => <AddressTag address={v} /> },
            { title: '贡献 Equity', dataIndex: 'equity_amount', width: 130, render: (v: number) => formatNumber(v || 0) },
            { title: 'App 合约', dataIndex: 'app_address', width: 180, render: (v: string) => <AddressTag address={v} /> },
            { title: '权益资产', dataIndex: 'equity_token', width: 180, render: (v: string) => v ? <AddressTag address={v} /> : '-' },
            { title: '交易', dataIndex: 'tx_hash', width: 180, render: (v: string) => <AddressTag address={v} /> },
          ]}
        />
      </Card>

      <Card title="操作面板" size="small">
        <Tabs
          items={[
            {
              key: 'demo',
              label: 'Demo 测试交易',
              children: (
                <Row gutter={[16, 16]}>
                  <Col xs={24} xl={8}>
                    <ActionPanel title="库存管理">
                      <Form form={mintForm} layout="vertical" initialValues={{ amount: 1000, max_gas: 400000, gas_unit_price: 100 }}>
                        <Form.Item name="amount" label="新增 Equity 库存" rules={[{ required: true }]}>
                          <InputNumber min={1} precision={0} style={{ width: '100%' }} />
                        </Form.Item>
                        <Row gutter={12}>
                          <Col span={12}>
                            <Form.Item name="max_gas" label="max_gas"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                          </Col>
                          <Col span={12}>
                            <Form.Item name="gas_unit_price" label="gas_unit_price"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                          </Col>
                        </Row>
                        <Button icon={<ThunderboltOutlined />} loading={submitting} disabled={!moduleAddress} onClick={handleMintEquity}>铸造到 Custody</Button>
                      </Form>
                    </ActionPanel>
                  </Col>

                  <Col xs={24} xl={16}>
                    <ActionPanel title="单次贡献交易">
                      <Form
                        form={buyForm}
                        layout="vertical"
                        initialValues={{
                          equity_amount: 1,
                          buyer_label: 'demo-buyer',
                          mint_octas: DEFAULT_BUYER_MINT,
                          max_gas: 400000,
                          gas_unit_price: 100,
                        }}
                      >
                        <Row gutter={12} align="bottom">
                          <Col xs={24} lg={8}>
                            <Form.Item name="buyer_address" label="买家地址">
                              <AddressSelect kind="user" allowAdd value={buyForm.getFieldValue('buyer_address')} onChange={(v) => buyForm.setFieldValue('buyer_address', v)} />
                            </Form.Item>
                          </Col>
                          <Col xs={24} lg={4}>
                            <Form.Item name="buyer_label" label="自动买家标签"><Input /></Form.Item>
                          </Col>
                          <Col xs={12} lg={4}>
                            <Form.Item name="equity_amount" label="Equity 数量" rules={[{ required: true }]}>
                              <InputNumber min={1} precision={0} style={{ width: '100%' }} />
                            </Form.Item>
                          </Col>
                          <Col xs={12} lg={4}>
                            <Form.Item name="mint_octas" label="买家铸币 octas">
                              <InputNumber min={0} precision={0} style={{ width: '100%' }} />
                            </Form.Item>
                          </Col>
                          <Col xs={12} lg={2}>
                            <Form.Item name="max_gas" label="max_gas"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                          </Col>
                          <Col xs={12} lg={2}>
                            <Form.Item name="gas_unit_price" label="gas"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                          </Col>
                        </Row>
                        <Space wrap>
                          <Button type="primary" loading={submitting} disabled={!moduleAddress} onClick={handleBuyEquity}>发送 buy_equity</Button>
                          <Tag color="blue">0x1::poc_contribution</Tag>
                          <Typography.Text type="secondary">预计支付 {formatNumber(payment)} octas ({formatTopo(payment)} TOPO)</Typography.Text>
                        </Space>
                      </Form>
                    </ActionPanel>
                  </Col>

                  <Col xs={24}>
                    <ActionPanel title="定时贡献交易">
                      <Form
                        form={autoForm}
                        layout="vertical"
                        initialValues={{
                          interval_secs: 5,
                          tx_per_tick: 1,
                          amount_min: 1,
                          amount_max: 10,
                          max_runs: 0,
                          auto_create_buyers: 1,
                          mint_octas: DEFAULT_BUYER_MINT,
                          max_gas: 400000,
                          gas_unit_price: 100,
                        }}
                      >
                        <Row gutter={12}>
                          <Col xs={12} md={4}><Form.Item name="interval_secs" label="间隔秒" rules={[{ required: true }]}><InputNumber min={1} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="tx_per_tick" label="每轮交易数" rules={[{ required: true }]}><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="amount_min" label="最小 Equity" rules={[{ required: true }]}><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="amount_max" label="最大 Equity" rules={[{ required: true }]}><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="max_runs" label="次数上限"><InputNumber min={0} precision={0} style={{ width: '100%' }} addonAfter="0不限" /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="auto_create_buyers" label="自动买家数"><InputNumber min={0} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="mint_octas" label="每个买家铸币"><InputNumber min={0} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="max_gas" label="max_gas"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={12} md={4}><Form.Item name="gas_unit_price" label="gas_unit_price"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item></Col>
                          <Col xs={24} md={12}>
                            <Form.Item name="buyer_addresses" label="固定买家地址">
                              <Input.TextArea rows={3} placeholder="可用逗号、空格或换行分隔；为空则自动生成" />
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Descriptions size="small" column={1} bordered>
                              <Descriptions.Item label="任务状态"><Tag color={autoTrade.status === 'running' ? 'green' : 'default'}>{autoTrade.status === 'running' ? '运行中' : '未运行'}</Tag></Descriptions.Item>
                              <Descriptions.Item label="执行结果">{formatNumber(autoTrade.success_count || 0)} 成功 / {formatNumber(autoTrade.failure_count || 0)} 失败</Descriptions.Item>
                              <Descriptions.Item label="刷新方式">WebSocket 事件推送</Descriptions.Item>
                            </Descriptions>
                          </Col>
                        </Row>
                        <Space wrap>
                          <Button type="primary" loading={submitting} disabled={!moduleAddress} onClick={handleStartAutoTrade}>启动定时交易</Button>
                          <Button danger loading={submitting} disabled={autoTrade.status !== 'running'} onClick={() => doAction('停止定时交易', () => stopDemoAutoTrade({ app_admin: admin! }))}>停止定时交易</Button>
                          <Tag color="blue">正式 POC 合约</Tag>
                        </Space>
                      </Form>
                    </ActionPanel>
                  </Col>
                </Row>
              ),
            },
            {
              key: 'platform',
              label: '平台 POC 管理',
              children: (
                <Row gutter={[16, 16]}>
                  <Col xs={24} lg={8}>
                    <ActionPanel title="快速操作">
                      <Space direction="vertical" style={{ width: '100%' }}>
                        <Button block type="primary" loading={submitting} onClick={() => runWithConfirm('确认加入白名单?', () => doAction('加入白名单', () => whitelistApp({ app_admin: admin! })))}>加入 POC 白名单</Button>
                        <Button block danger loading={submitting} onClick={() => runWithConfirm('确认暂停 POC 资格?', () => doAction('暂停 POC', () => setPocStatus({ app_admin: admin!, status: 3 })))}>暂停 POC 资格</Button>
                      </Space>
                    </ActionPanel>
                  </Col>
                  <Col xs={24} lg={8}>
                    <ActionPanel title="状态设置">
                      <Form form={pocForm} layout="vertical" initialValues={{ status: d.poc_listing_status_code || 1 }}>
                        <Form.Item name="status" label="POC 纳入状态">
                          <Select options={[
                            { value: 1, label: 'REGISTERED - 已注册' },
                            { value: 2, label: 'WHITELISTED - 可计入' },
                            { value: 3, label: 'SUSPENDED - 已暂停' },
                          ]} />
                        </Form.Item>
                        <Button loading={submitting} onClick={async () => {
                          const values = await pocForm.validateFields();
                          doAction('设置 POC 状态', () => setPocStatus({ app_admin: admin!, status: values.status }));
                        }}>设置状态</Button>
                      </Form>
                    </ActionPanel>
                  </Col>
                  <Col xs={24} lg={8}>
                    <ActionPanel title="权重设置">
                      <Form form={weightForm} layout="vertical" initialValues={{ weight_pbs: d.effective_weight_pbs || 10000 }}>
                        <Form.Item
                          name="weight_pbs"
                          label={(
                            <Space>
                              <span>有效权重 pbs</span>
                              <InfoCircleOutlined title="10000 pbs = 100%" />
                            </Space>
                          )}
                        >
                          <InputNumber min={0} max={10000} precision={0} style={{ width: '100%' }} addonAfter="pbs" />
                        </Form.Item>
                        <Button loading={submitting} onClick={async () => {
                          const values = await weightForm.validateFields();
                          doAction('设置权重', () => setWeight({ app_admin: admin!, weight_pbs: values.weight_pbs }));
                        }}>设置权重</Button>
                      </Form>
                    </ActionPanel>
                  </Col>
                </Row>
              ),
            },
            {
              key: 'app',
              label: 'App 自主管理',
              children: (
                <Row gutter={[16, 16]}>
                  <Col xs={24} lg={8}>
                    <ActionPanel title="运行状态">
                      <Space direction="vertical" style={{ width: '100%' }}>
                        <Button block icon={<PauseCircleOutlined />} loading={submitting} onClick={() => runWithConfirm('确认暂停应用?', () => doAction('暂停应用', () => pauseApp({ app_admin: admin! })))}>暂停应用</Button>
                        <Button block icon={<PlayCircleOutlined />} loading={submitting} onClick={() => doAction('恢复应用', () => resumeApp({ app_admin: admin! }))}>恢复应用</Button>
                        <Button block danger icon={<StopOutlined />} loading={submitting} onClick={() => runWithConfirm('确认永久停止应用? 停止后不能恢复', () => doAction('永久停止', () => stopApp({ app_admin: admin! })))}>永久停止</Button>
                      </Space>
                    </ActionPanel>
                  </Col>
                  <Col xs={24} lg={16}>
                    <ActionPanel title="注册地址更新">
                      <Form form={updateForm} layout="vertical" initialValues={{ target: 'app' }}>
                        <Row gutter={12} align="bottom">
                          <Col xs={24} md={8}>
                            <Form.Item name="target" label="更新字段" rules={[{ required: true }]}>
                              <Select options={[
                                { value: 'app', label: 'App 合约地址' },
                                { value: 'custody', label: '库存托管地址' },
                                { value: 'equity', label: '权益资产地址' },
                              ]} />
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={12}>
                            <Form.Item name="new_address" label="新地址" rules={[{ required: true }]}>
                              <Input placeholder="0x..." />
                            </Form.Item>
                          </Col>
                          <Col xs={24} md={4}>
                            <Form.Item label=" ">
                              <Button block loading={submitting} onClick={handleUpdateAddress}>更新</Button>
                            </Form.Item>
                          </Col>
                        </Row>
                      </Form>
                    </ActionPanel>
                  </Col>
                </Row>
              ),
            },
            {
              key: 'register',
              label: '手动注册正式 DApp',
              children: (
                <ActionPanel title="注册信息">
                  <Form form={manualForm} layout="vertical">
                    <Row gutter={12} align="bottom">
                      <Col xs={24} lg={6}><Form.Item name="app_address" label="App 合约地址" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
                      <Col xs={24} lg={6}><Form.Item name="equity_token_address" label="权益资产地址" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
                      <Col xs={24} lg={6}><Form.Item name="custody_address" label="库存托管地址" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
                      <Col xs={24} lg={4}><Form.Item name="metadata_uri" label="Metadata URI"><Input placeholder="https://..." /></Form.Item></Col>
                      <Col xs={24} lg={2}><Form.Item label=" "><Button block loading={submitting} onClick={handleRegisterManual}>注册</Button></Form.Item></Col>
                    </Row>
                  </Form>
                </ActionPanel>
              ),
            },
          ]}
        />
      </Card>
    </div>
  );
}
