import { useState } from 'react';
import { Alert, Card, Form, InputNumber, Button, message, Radio, Space, Typography } from 'antd';
import { KeyOutlined } from '@ant-design/icons';
import { prepareJoin } from '../../services/validator';
import { generateAccount } from '../../services/watchlist';
import StepProgress from '../../components/StepProgress';
import AddressSelect from '../../components/AddressSelect';
import AddressTag from '../../components/AddressTag';
import { octasToTopo, topoToOctas } from '../../utils/format';
import { DEFAULT_VALIDATOR_STAKE_OCTAS, MIN_VALIDATOR_STAKE_OCTAS } from '../../utils/constants';

const { Text } = Typography;

export default function AddValidator() {
  const [form] = Form.useForm();
  const [running, setRunning] = useState(false);
  const [steps, setSteps] = useState<any[]>([]);
  const [current, setCurrent] = useState(-1);
  const [accountMode, setAccountMode] = useState<'generate' | 'existing'>('generate');
  const [generatedAccount, setGeneratedAccount] = useState<any>(null);
  const defaultValidatorStakeTopo = octasToTopo(DEFAULT_VALIDATOR_STAKE_OCTAS);

  const STEP_NAMES = ['create_account', 'mint_topo', 'set_power_period', 'force_end_epoch_after_set_power_period', 'stage_power', 'force_end_epoch', 'initialize_validator', 'register_validator', 'deposit', 'delegate_self', 'join_validator_set', 'force_end_epoch_after_join'];

  const handleSubmit = async () => {
    const values = await form.validateFields();
    setRunning(true);
    setSteps(STEP_NAMES.map((s) => ({ step: s, status: 'pending' })));
    setCurrent(0);

    try {
      let validatorAddress = values.validator_address || '';
      let generated = generatedAccount;
      if (accountMode === 'generate') {
        if (!generated) {
          generated = await generateAccount({ kind: 'validator', label: values.label || undefined });
          setGeneratedAccount(generated);
        }
        validatorAddress = generated.address;
        form.setFieldValue('validator_address', validatorAddress);
      }

      const result = await prepareJoin({
        validator_address: validatorAddress,
        label: values.label || undefined,
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
        if (result.validator_address && result.validator_address !== validatorAddress) {
          form.setFieldValue('validator_address', result.validator_address);
        }
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
        <Form form={form} layout="vertical" initialValues={{ power: DEFAULT_VALIDATOR_STAKE_OCTAS, power_period: 5, force_epochs: 5, force_epochs_after_join: 1, mint_topo: defaultValidatorStakeTopo + octasToTopo(MIN_VALIDATOR_STAKE_OCTAS), deposit_topo: defaultValidatorStakeTopo, commission: 0 }}>
          <Form.Item label="账户来源">
            <Radio.Group
              value={accountMode}
              onChange={(e) => {
                setAccountMode(e.target.value as 'generate' | 'existing');
                setGeneratedAccount(null);
                form.setFieldValue('validator_address', '');
              }}
              optionType="button"
              buttonStyle="solid"
            >
              <Radio.Button value="generate">生成新账户</Radio.Button>
              <Radio.Button value="existing">使用已有地址</Radio.Button>
            </Radio.Group>
          </Form.Item>
          {accountMode === 'existing' ? (
            <Form.Item name="validator_address" label="验证者地址" rules={[{ required: true, message: '请选择验证者地址' }]}>
              <AddressSelect kind="validator" value={form.getFieldValue('validator_address')} onChange={(v) => form.setFieldValue('validator_address', v)} />
            </Form.Item>
          ) : (
            <Form.Item label="生成的验证者账户">
              {generatedAccount ? (
                <Alert
                  type="success"
                  showIcon
                  message="验证者账户已生成"
                  description={(
                    <Space direction="vertical" style={{ width: '100%' }}>
                      <span>地址：<AddressTag address={generatedAccount.address} short={false} /></span>
                      <Text copyable={{ text: generatedAccount.public_key }} style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                        公钥：{generatedAccount.public_key}
                      </Text>
                      <Text copyable={{ text: generatedAccount.private_key }} style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                        私钥：{generatedAccount.private_key}
                      </Text>
                    </Space>
                  )}
                />
              ) : (
                <Alert
                  type="info"
                  showIcon
                  icon={<KeyOutlined />}
                  message="提交时会自动生成验证者私钥和地址，并托管到本地数据库。"
                />
              )}
            </Form.Item>
          )}
          <Form.Item name="label" label="验证者名（可选）">
            <input className="ant-input" placeholder="如: 验证者4" />
          </Form.Item>
          <Form.Item name="power" label="目标算力"><InputNumber min={0} style={{ width: '100%' }} /></Form.Item>
          <Form.Item name="mint_topo" label="铸造 TOPO 数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
          <Form.Item name="deposit_topo" label="保证金数量"><InputNumber min={0} style={{ width: '100%' }} addonAfter="TOPO" /></Form.Item>
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
