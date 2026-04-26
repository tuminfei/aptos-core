import { useState } from 'react';
import { Card, Tabs, Form, InputNumber, Button, Checkbox, Table, Space, message } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import { proxyStake } from '../services/staking';
import StepProgress from '../components/StepProgress';
import AddressSelect from '../components/AddressSelect';
import { topoToOctas } from '../utils/format';

export default function ProxyStake() {
  const [form] = Form.useForm();
  const [running, setRunning] = useState(false);
  const [steps, setSteps] = useState<any[]>([]);
  const [current, setCurrent] = useState(-1);

  const [batchValidator, setBatchValidator] = useState('');
  const [batchRows, setBatchRows] = useState<any[]>([{ key: '1', address: '', mint: 1000, power: 5000, deposit: 500 }]);
  const [batchResults, setBatchResults] = useState<any[]>([]);
  const [batchRunning, setBatchRunning] = useState(false);

  const handleSingle = async () => {
    const values = await form.validateFields();
    setRunning(true);
    setSteps([
      { step: 'mint_topo', status: 'pending' },
      { step: 'stage_power', status: 'pending' },
      ...(values.force_epoch ? [{ step: 'force_end_epoch', status: 'pending' }] : []),
      { step: 'deposit', status: 'pending' },
      { step: 'delegate', status: 'pending' },
    ]);
    setCurrent(0);

    try {
      const result = await proxyStake({
        target_user: values.target_user,
        mint_amount: topoToOctas(values.mint_amount),
        set_power: values.set_power,
        deposit_amount: topoToOctas(values.deposit_amount),
        delegate_to: values.delegate_to,
        force_epoch: values.force_epoch || false,
      });
      setSteps(result.steps || []);
      setCurrent(result.steps?.length || 0);
      message.info(result.final_status === 'success' ? '代理质押完成' : '部分步骤失败');
    } catch {
      message.error('执行失败');
    }
    setRunning(false);
  };

  const handleBatch = async () => {
    setBatchRunning(true);
    const results: any[] = [];
    for (const row of batchRows) {
      if (!row.address) continue;
      try {
        const result = await proxyStake({
          target_user: row.address,
          mint_amount: topoToOctas(row.mint),
          set_power: row.power,
          deposit_amount: topoToOctas(row.deposit),
          delegate_to: batchValidator,
          force_epoch: false,
        });
        results.push({ address: row.address, ...result });
      } catch (e: any) {
        results.push({ address: row.address, final_status: 'failed', error: e.message });
      }
      setBatchResults([...results]);
    }
    setBatchRunning(false);
    message.info('批量执行完成');
  };

  const addRow = () => {
    setBatchRows([...batchRows, { key: String(batchRows.length + 1), address: '', mint: 1000, power: 5000, deposit: 500 }]);
  };

  const updateRow = (index: number, field: string, value: any) => {
    const rows = [...batchRows];
    rows[index] = { ...rows[index], [field]: value };
    setBatchRows(rows);
  };

  const batchColumns = [
    { title: '用户', dataIndex: 'address', width: 280, render: (_: any, __: any, i: number) => <AddressSelect kind="user" value={batchRows[i]?.address || undefined} onChange={(v) => updateRow(i, 'address', v)} style={{ width: 260 }} /> },
    { title: '铸造TOPO', dataIndex: 'mint', render: (_: any, __: any, i: number) => <InputNumber value={batchRows[i]?.mint} onChange={(v) => updateRow(i, 'mint', v)} size="small" min={0} /> },
    { title: '算力', dataIndex: 'power', render: (_: any, __: any, i: number) => <InputNumber value={batchRows[i]?.power} onChange={(v) => updateRow(i, 'power', v)} size="small" min={0} /> },
    { title: '存款TOPO', dataIndex: 'deposit', render: (_: any, __: any, i: number) => <InputNumber value={batchRows[i]?.deposit} onChange={(v) => updateRow(i, 'deposit', v)} size="small" min={0} /> },
  ];

  return (
    <Tabs items={[
      {
        key: 'single', label: '单用户模式', children: (
          <div>
            <Card title="代理质押 — 为用户一键完成铸币+算力+存款+委托" style={{ marginBottom: 16 }}>
              <Form form={form} layout="vertical" initialValues={{ mint_amount: 1000, set_power: 5000, deposit_amount: 500 }}>
                <Form.Item name="target_user" label="目标用户" rules={[{ required: true }]}>
                  <AddressSelect kind="user" value={form.getFieldValue('target_user')} onChange={(v) => form.setFieldValue('target_user', v)} />
                </Form.Item>
                <Form.Item name="mint_amount" label="铸造数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
                <Form.Item name="set_power" label="设置算力"><InputNumber min={0} style={{ width: '100%' }} /></Form.Item>
                <Form.Item name="deposit_amount" label="存款数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
                <Form.Item name="delegate_to" label="委托验证者" rules={[{ required: true }]}>
                  <AddressSelect kind="validator" value={form.getFieldValue('delegate_to')} onChange={(v) => form.setFieldValue('delegate_to', v)} />
                </Form.Item>
                <Form.Item name="force_epoch" valuePropName="checked"><Checkbox>强制Epoch</Checkbox></Form.Item>
                <Button type="primary" onClick={handleSingle} loading={running}>执行代理质押</Button>
              </Form>
            </Card>
            {steps.length > 0 && <Card title="执行进度"><StepProgress steps={steps} current={current} /></Card>}
          </div>
        ),
      },
      {
        key: 'batch', label: '批量模式', children: (
          <div>
            <Card title="批量代理质押" style={{ marginBottom: 16 }}>
              <Space style={{ marginBottom: 16 }}>
                <span>委托验证者:</span>
                <AddressSelect kind="validator" value={batchValidator || undefined} onChange={setBatchValidator} style={{ width: 400 }} />
              </Space>
              <Table dataSource={batchRows} columns={batchColumns} rowKey="key" size="small" pagination={false} />
              <Space style={{ marginTop: 16 }}>
                <Button icon={<PlusOutlined />} onClick={addRow}>添加行</Button>
                <Button type="primary" onClick={handleBatch} loading={batchRunning}>批量执行</Button>
              </Space>
            </Card>
            {batchResults.length > 0 && (
              <Card title="执行结果">
                {batchResults.map((r, i) => (
                  <div key={i} style={{ marginBottom: 8 }}>
                    用户 {r.address?.slice(0, 10)}...: {r.final_status === 'success' ? '✅ 成功' : `❌ 失败 ${r.error || ''}`}
                  </div>
                ))}
              </Card>
            )}
          </div>
        ),
      },
    ]} />
  );
}
