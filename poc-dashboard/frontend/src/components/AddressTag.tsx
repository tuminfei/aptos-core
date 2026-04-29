import { Typography, Space, Tooltip } from 'antd';
import { CopyOutlined } from '@ant-design/icons';
import { shortenAddress } from '../utils/format';
import { useAddressBook } from '../contexts/AddressBookContext';

interface Props {
  address: string;
  short?: boolean;
  name?: string;
  showAddress?: boolean;
}

export default function AddressTag({ address, short = true, name, showAddress = false }: Props) {
  const { nameOf } = useAddressBook();
  const displayName = name || nameOf(address);
  const displayText = displayName || (short ? shortenAddress(address) : address);
  const secondaryText = displayName && showAddress ? ` ${shortenAddress(address)}` : '';

  return (
    <Space size={4}>
      <Tooltip title={address}>
        <Typography.Text
          copyable={{ text: address, icon: <CopyOutlined style={{ fontSize: 12 }} /> }}
          style={{ fontFamily: displayName ? undefined : 'monospace', fontSize: 13 }}
        >
          {displayText}
          {secondaryText && <Typography.Text type="secondary">{secondaryText}</Typography.Text>}
        </Typography.Text>
      </Tooltip>
    </Space>
  );
}
