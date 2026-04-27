import { useState } from 'react';
import { Card, Form, InputNumber, Button, message } from 'antd';
import { prepareJoin } from '../../services/validator';
import { addToWatchlist } from '../../services/watchlist';
import StepProgress from '../../components/StepProgress';
import AddressSelect from '../../components/AddressSelect';
import { octasToTopo, topoToOctas } from '../../utils/format';
import { DEFAULT_VALIDATOR_STAKE_OCTAS, MIN_VALIDATOR_STAKE_OCTAS } from '../../utils/constants';

export default function AddValidator() {
  const [form] = Form.useForm();
  const [running, setRunning] = useState(false);
  const [steps, setSteps] = useState<any[]>([]);
  const [current, setCurrent] = useState(-1);
  const defaultValidatorStakeTopo = octasToTopo(DEFAULT_VALIDATOR_STAKE_OCTAS);

  const STEP_NAMES = ['create_account', 'mint_topo', 'set_power_period', 'force_end_epoch_after_set_power_period', 'stage_power', 'force_end_epoch', 'initialize_validator', 'register_validator', 'deposit', 'delegate_self', 'join_validator_set', 'force_end_epoch_after_join'];

  const handleSubmit = async () => {
    const values = await form.validateFields();
    setRunning(true);
    setSteps(STEP_NAMES.map((s) => ({ step: s, status: 'pending' })));
    setCurrent(0);

    try {
      const result = await prepareJoin({
        validator_address: values.validator_address,
        power: values.power,
        set_power_period: values.power_period,
        force_epochs_before_delegate: values.force_epochs,
        force_epochs_after_join: values.force_epochs_after_join,
        mint_amount: topoToOctas(values.mint_topo),
        deposit_amount: topoToOctas(values.deposit_topo),
        commission_bps: values.commission * 100,
      });

      const newSteps = STEP_NAMES.map((name) => {
        const s = result.steps?.find((rs: any) => rs.step === name || rs.step.startsWith(name));
        return s || { step: name, status: 'pending' };
      });
      setSteps(newSteps);
      setCurrent(newSteps.length);

      if (result.final_status === 'success') {
        await addToWatchlist({ kind: 'validator', address: values.validator_address, label: values.label || undefined });
        message.success('验证者添加成功，已保存到列表');
      } else {
        message.error('部分步骤失败，请查看详情');
      }
    } catch {
      message.error('执行失败');
    }
    setRunning(false);
  };

  return (
    <div>
      <Card title="添加新验证者" style={{ marginBottom: 16 }}>
        <Form form={form} layout="vertical" initialValues={{ power: DEFAULT_VALIDATOR_STAKE_OCTAS, power_period: 1, force_epochs: 1, force_epochs_after_join: 1, mint_topo: defaultValidatorStakeTopo + octasToTopo(MIN_VALIDATOR_STAKE_OCTAS), deposit_topo: defaultValidatorStakeTopo, commission: 0 }}>
          <Form.Item name="validator_address" label="验证者地址" rules={[{ required: true }]}>
            <AddressSelect kind="validator" value={form.getFieldValue('validator_address')} onChange={(v) => form.setFieldValue('validator_address', v)} />
          </Form.Item>
          <Form.Item name="label" label="备注（可选）">
            <input className="ant-input" placeholder="如: validator-4" />
          </Form.Item>
          <Form.Item name="power" label="目标算力"><InputNumber min={0} style={{ width: '100%' }} /></Form.Item>
          <Form.Item name="mint_topo" label="铸造 TOPO 数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
          <Form.Item name="deposit_topo" label="存款数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
          <Form.Item name="commission" label="佣金比例"><InputNumber min={0} max={100} style={{ width: '100%' }} addonAfter="%" /></Form.Item>
          <Form.Item name="power_period" label="算力周期 (Epoch)"><InputNumber min={1} style={{ width: '100%' }} /></Form.Item>
          <Form.Item name="force_epochs" label="强制Epoch次数"><InputNumber min={0} style={{ width: '100%' }} /></Form.Item>
          <Form.Item name="force_epochs_after_join" label="加入后强制Epoch次数"><InputNumber min={0} style={{ width: '100%' }} /></Form.Item>
          <Button type="primary" onClick={handleSubmit} loading={running}>开始执行</Button>
        </Form>
      </Card>

      {steps.length > 0 && (
        <Card title="执行进度">
          <StepProgress steps={steps} current={current} />
        </Card>
      )}
    </div>
  );
}
