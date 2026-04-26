import { Tag } from 'antd';
import { VALIDATOR_STATUS_LABEL, VALIDATOR_STATUS_COLOR } from '../utils/constants';

interface Props {
  status: string;
}

export default function StatusBadge({ status }: Props) {
  return (
    <Tag color={VALIDATOR_STATUS_COLOR[status] || 'default'}>
      {VALIDATOR_STATUS_LABEL[status] || status}
    </Tag>
  );
}
