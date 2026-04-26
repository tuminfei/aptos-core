import { Steps } from 'antd';

interface Step {
  step: string;
  status: 'success' | 'failed' | 'pending' | 'running';
  tx_hash?: string;
  error?: string;
}

interface Props {
  steps: Step[];
  current: number;
}

const statusMap: Record<string, 'finish' | 'error' | 'process' | 'wait'> = {
  success: 'finish',
  failed: 'error',
  running: 'process',
  pending: 'wait',
};

export default function StepProgress({ steps, current }: Props) {
  return (
    <Steps
      current={current}
      direction="vertical"
      size="small"
      items={steps.map((s) => ({
        title: s.step,
        status: statusMap[s.status] || 'wait',
        description: s.tx_hash ? `tx: ${s.tx_hash.slice(0, 12)}...` : s.error || undefined,
      }))}
    />
  );
}
