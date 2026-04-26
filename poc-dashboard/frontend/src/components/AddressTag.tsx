import { Typography, Space } from 'antd';
import { CopyOutlined } from '@ant-design/icons';
import { shortenAddress } from '../utils/format';

interface Props {
  address: string;
  short?: boolean;
}

export default function AddressTag({ address, short = true }: Props) {
  return (
    <Space size={4}>
      <Typography.Text copyable={{ text: address, icon: <CopyOutlined style={{ fontSize: 12 }} /> }} style={{ fontFamily: 'monospace', fontSize: 13 }}>
        {short ? shortenAddress(address) : address}
      </Typography.Text>
    </Space>
  );
}
