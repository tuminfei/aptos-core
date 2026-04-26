import { Modal, Descriptions } from 'antd';

interface Props {
  open: boolean;
  title: string;
  action: string;
  target?: string;
  params?: Record<string, unknown>;
  functionId?: string;
  loading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmModal({ open, title, action, target, params, functionId, loading, onConfirm, onCancel }: Props) {
  return (
    <Modal title={title} open={open} onOk={onConfirm} onCancel={onCancel} confirmLoading={loading} okText="确认执行" cancelText="取消">
      <Descriptions column={1} size="small" bordered>
        <Descriptions.Item label="操作">{action}</Descriptions.Item>
        {target && <Descriptions.Item label="目标">{target}</Descriptions.Item>}
        {params && Object.entries(params).map(([k, v]) => (
          <Descriptions.Item key={k} label={k}>{String(v)}</Descriptions.Item>
        ))}
        {functionId && <Descriptions.Item label="调用">{functionId}</Descriptions.Item>}
      </Descriptions>
    </Modal>
  );
}
