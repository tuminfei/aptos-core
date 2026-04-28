import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import {
  Alert,
  Button,
  Card,
  Checkbox,
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
} from '@ant-design/icons';
import {
  buyDemoEquity,
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
import { formatNumber, formatTopo } from '../../utils/format';

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

export default function DAppDetail() {
  const { admin } = useParams<{ admin: string }>();
  const fetchDApp = useCallback(() => getDApp(admin!), [admin]);
  const { data, loading, refresh } = usePolling(fetchDApp, 0, [admin]);
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

  const d = data || {};
  const info = d.info || {};
  const demo = d.demo || {};
  const autoTrade = d.auto_trade || {};
  const moduleAddress = demo.module_address || '';
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

  return (
    <div>
      <Card
        loading={loading}
        style={{ marginBottom: 16 }}
        title={<Space>DApp <AddressTag address={admin || ''} /></Space>}
        extra={<Button icon={<SyncOutlined />} onClick={refresh}>刷新</Button>}
      >
        <Descriptions bordered column={{ xs: 1, sm: 1, md: 2, xl: 3 }} size="small">
          <Descriptions.Item label="应用状态"><Tag color={APP_STATE_COLOR[d.app_state_code]}>{APP_STATE_LABEL[d.app_state_code] || '未知'}</Tag></Descriptions.Item>
          <Descriptions.Item label="POC状态"><Tag color={POC_STATUS_COLOR[d.poc_listing_status_code]}>{POC_STATUS_LABEL[d.poc_listing_status_code] || '未知'}</Tag></Descriptions.Item>
          <Descriptions.Item label="贡献可计入"><Tag color={d.eligible_for_poc ? 'green' : 'default'}>{d.eligible_for_poc ? '是' : '否'}</Tag></Descriptions.Item>
          <Descriptions.Item label="权重">{d.effective_weight_pbs ? `${(d.effective_weight_pbs / 100).toFixed(1)}%` : '-'}</Descriptions.Item>
          <Descriptions.Item label="App Address">{valueFromInfo(info, 'app_address') === '-' ? '-' : <AddressTag address={String(valueFromInfo(info, 'app_address'))} />}</Descriptions.Item>
          <Descriptions.Item label="Equity Token">{valueFromInfo(info, 'equity_token_address') === '-' ? '-' : <AddressTag address={String(valueFromInfo(info, 'equity_token_address'))} />}</Descriptions.Item>
          <Descriptions.Item label="Custody">{valueFromInfo(info, 'custody_address') === '-' ? '-' : <AddressTag address={String(valueFromInfo(info, 'custody_address'))} />}</Descriptions.Item>
          <Descriptions.Item label="metadata_uri" span={2}>{String(valueFromInfo(info, 'metadata_uri'))}</Descriptions.Item>
          <Descriptions.Item label="Demo Module">{moduleAddress ? <AddressTag address={moduleAddress} /> : '-'}</Descriptions.Item>
        </Descriptions>
      </Card>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} lg={8}>
          <Card size="small" title="Demo 交易状态">
            <Row gutter={12}>
              <Col span={8}><Statistic title="交易数" value={formatNumber(demo.trade_count || 0)} /></Col>
              <Col span={8}><Statistic title="售出 Equity" value={formatNumber(demo.total_equity_sold || 0)} /></Col>
              <Col span={8}><Statistic title="库存" value={formatNumber(demo.custody_inventory || 0)} /></Col>
            </Row>
            <Descriptions size="small" column={1} style={{ marginTop: 12 }}>
              <Descriptions.Item label="单价">{formatNumber(demo.price_per_equity || 0)} octas</Descriptions.Item>
              <Descriptions.Item label="已配置">{demo.configured ? '是' : '否'}</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
        <Col xs={24} lg={8}>
          <Card size="small" title="定时任务">
            <Descriptions size="small" column={1}>
              <Descriptions.Item label="状态"><Tag color={autoTrade.status === 'running' ? 'green' : 'default'}>{autoTrade.status || '未运行'}</Tag></Descriptions.Item>
              <Descriptions.Item label="执行次数">{formatNumber(autoTrade.run_count || 0)} / {autoTrade.max_runs ? formatNumber(autoTrade.max_runs) : '不限'}</Descriptions.Item>
              <Descriptions.Item label="成功 / 失败">{formatNumber(autoTrade.success_count || 0)} / {formatNumber(autoTrade.failure_count || 0)}</Descriptions.Item>
              <Descriptions.Item label="最后 TX">{autoTrade.last_tx_hash ? <AddressTag address={autoTrade.last_tx_hash} /> : '-'}</Descriptions.Item>
            </Descriptions>
          </Card>
        </Col>
        <Col xs={24} lg={8}>
          <Alert
            type={d.eligible_for_poc ? 'success' : 'warning'}
            showIcon
            message={d.eligible_for_poc ? '当前贡献事件会进入 POC 统计前提' : '贡献事件可能不会被 POC 统计'}
            description="需要应用状态 ACTIVE 且 POC 状态 WHITELISTED。Demo buy_equity 会调用正式 0x1::poc_contribution。"
          />
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} xl={12}>
          <Card title="App 自主管理" size="small">
            <Space wrap style={{ marginBottom: 16 }}>
              <Button icon={<PauseCircleOutlined />} loading={submitting} onClick={() => runWithConfirm('确认暂停应用?', () => doAction('暂停应用', () => pauseApp({ app_admin: admin! })))}>暂停</Button>
              <Button icon={<PlayCircleOutlined />} loading={submitting} onClick={() => doAction('恢复应用', () => resumeApp({ app_admin: admin! }))}>恢复</Button>
              <Button danger icon={<StopOutlined />} loading={submitting} onClick={() => runWithConfirm('确认永久停止应用? 停止后不能恢复', () => doAction('永久停止', () => stopApp({ app_admin: admin! })))}>永久停止</Button>
            </Space>
            <Form form={updateForm} layout="vertical" initialValues={{ target: 'app' }}>
              <Row gutter={12} align="bottom">
                <Col xs={24} md={8}>
                  <Form.Item name="target" label="更新字段" rules={[{ required: true }]}>
                    <Select options={[
                      { value: 'app', label: 'App Address' },
                      { value: 'custody', label: 'Custody Address' },
                      { value: 'equity', label: 'Equity Token Address' },
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
          </Card>
        </Col>

        <Col xs={24} xl={12}>
          <Card title="平台 POC 管理" size="small">
            <Space wrap style={{ marginBottom: 16 }}>
              <Button type="primary" loading={submitting} onClick={() => runWithConfirm('确认加入白名单?', () => doAction('加入白名单', () => whitelistApp({ app_admin: admin! })))}>加入白名单</Button>
              <Button danger loading={submitting} onClick={() => runWithConfirm('确认暂停 POC 资格?', () => doAction('暂停 POC', () => setPocStatus({ app_admin: admin!, status: 3 })))}>暂停 POC</Button>
            </Space>
            <Row gutter={12}>
              <Col xs={24} md={12}>
                <Form form={pocForm} layout="vertical" initialValues={{ status: d.poc_listing_status_code || 1 }}>
                  <Form.Item name="status" label="POC 状态">
                    <Select options={[
                      { value: 1, label: 'REGISTERED' },
                      { value: 2, label: 'WHITELISTED' },
                      { value: 3, label: 'SUSPENDED' },
                    ]} />
                  </Form.Item>
                  <Button loading={submitting} onClick={async () => {
                    const values = await pocForm.validateFields();
                    doAction('设置 POC 状态', () => setPocStatus({ app_admin: admin!, status: values.status }));
                  }}>设置状态</Button>
                </Form>
              </Col>
              <Col xs={24} md={12}>
                <Form form={weightForm} layout="vertical" initialValues={{ weight_pbs: d.effective_weight_pbs || 10000 }}>
                  <Form.Item name="weight_pbs" label="权重 pbs">
                    <InputNumber min={0} max={10000} precision={0} style={{ width: '100%' }} addonAfter="pbs" />
                  </Form.Item>
                  <Button loading={submitting} onClick={async () => {
                    const values = await weightForm.validateFields();
                    doAction('设置权重', () => setWeight({ app_admin: admin!, weight_pbs: values.weight_pbs }));
                  }}>设置权重</Button>
                </Form>
              </Col>
            </Row>
          </Card>
        </Col>
      </Row>

      <Card title="手动注册正式 DApp" size="small" style={{ marginBottom: 16 }}>
        <Form form={manualForm} layout="vertical">
          <Row gutter={12} align="bottom">
            <Col xs={24} lg={6}><Form.Item name="app_address" label="App Address" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
            <Col xs={24} lg={6}><Form.Item name="equity_token_address" label="Equity Token Address" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
            <Col xs={24} lg={6}><Form.Item name="custody_address" label="Custody Address" rules={[{ required: true }]}><Input placeholder="0x..." /></Form.Item></Col>
            <Col xs={24} lg={4}><Form.Item name="metadata_uri" label="metadata_uri"><Input placeholder="https://..." /></Form.Item></Col>
            <Col xs={24} lg={2}><Form.Item label=" "><Button block loading={submitting} onClick={handleRegisterManual}>注册</Button></Form.Item></Col>
          </Row>
        </Form>
      </Card>

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={10}>
          <Card title="Demo 库存管理" size="small">
            <Form form={mintForm} layout="vertical" initialValues={{ amount: 1000, max_gas: 400000, gas_unit_price: 100 }}>
              <Row gutter={12} align="bottom">
                <Col xs={24} md={12}>
                  <Form.Item name="amount" label="新增 Equity 库存" rules={[{ required: true }]}>
                    <InputNumber min={1} precision={0} style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
                <Col xs={12} md={6}>
                  <Form.Item name="max_gas" label="max_gas"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                </Col>
                <Col xs={12} md={6}>
                  <Form.Item name="gas_unit_price" label="gas_unit_price"><InputNumber min={1} precision={0} style={{ width: '100%' }} /></Form.Item>
                </Col>
              </Row>
              <Button icon={<ThunderboltOutlined />} loading={submitting} disabled={!moduleAddress} onClick={handleMintEquity}>铸造到 Custody</Button>
            </Form>
          </Card>
        </Col>

        <Col xs={24} xl={14}>
          <Card title="单次贡献交易" size="small">
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
                  <Form.Item name="buyer_address" label="买家">
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
                  <Form.Item name="mint_octas" label="自动铸币 octas">
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
                <Typography.Text type="secondary">预计支付 {formatNumber(payment)} octas ({formatTopo(payment)} TOPO)</Typography.Text>
              </Space>
            </Form>
          </Card>
        </Col>

        <Col xs={24}>
          <Card title="定时贡献交易" size="small">
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
                  <Alert type="info" showIcon message="定时任务参数" description="启动后后端按间隔推送交易状态，不需要整页刷新。已有任务会被新任务替换。" />
                </Col>
              </Row>
              <Space wrap>
                <Button type="primary" loading={submitting} disabled={!moduleAddress} onClick={handleStartAutoTrade}>启动定时交易</Button>
                <Button danger loading={submitting} disabled={autoTrade.status !== 'running'} onClick={() => doAction('停止定时交易', () => stopDemoAutoTrade({ app_admin: admin! }))}>停止定时交易</Button>
                <Checkbox checked disabled>使用正式 0x1::poc_contribution 产生贡献值事件</Checkbox>
              </Space>
            </Form>
          </Card>
        </Col>
      </Row>
    </div>
  );
}
