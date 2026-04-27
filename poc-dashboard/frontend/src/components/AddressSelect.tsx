import { useState, useEffect, useCallback } from 'react';
import { Select, Space, Input, Button, message } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import { getWatchedUsers, getWatchedValidators, addToWatchlist } from '../services/watchlist';
import { shortenAddress } from '../utils/format';

interface Props {
  kind: 'user' | 'validator';
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  style?: React.CSSProperties;
  allowAdd?: boolean;
}

interface Option {
  address: string;
  label: string;
  extra?: string;
}

export default function AddressSelect({ kind, value, onChange, placeholder, style, allowAdd = true }: Props) {
  const [options, setOptions] = useState<Option[]>([]);
  const [loading, setLoading] = useState(false);
  const [adding, setAdding] = useState(false);
  const [newAddr, setNewAddr] = useState('');
  const [newLabel, setNewLabel] = useState('');

  const fetchOptions = useCallback(async () => {
    setLoading(true);
    try {
      if (kind === 'user') {
        const data = await getWatchedUsers();
        setOptions((data.users || []).map((u: any) => ({
          address: u.address,
          label: u.label,
          extra: `${u.balance_topo?.toFixed(1) ?? 0} TOPO | 算力 ${u.committed_power ?? 0}`,
        })));
      } else {
        const data = await getWatchedValidators();
        setOptions((data.validators || []).map((v: any) => ({
          address: v.address,
          label: v.label,
          extra: v.status ? `${v.status} | 投票权 ${v.voting_power ?? 0}` : '',
        })));
      }
    } catch {}
    setLoading(false);
  }, [kind]);

  useEffect(() => { fetchOptions(); }, [fetchOptions]);

  const handleAdd = async () => {
    if (!newAddr.startsWith('0x') || newAddr.length < 4) {
      message.warning('请输入有效的 0x 地址');
      return;
    }
    try {
      await addToWatchlist({ kind, address: newAddr, label: newLabel || undefined });
      message.success('添加成功');
      setNewAddr('');
      setNewLabel('');
      setAdding(false);
      await fetchOptions();
      onChange?.(newAddr);
    } catch {}
  };

  const kindLabel = kind === 'user' ? '用户' : '验证者';
  const containerStyle: React.CSSProperties = style || { width: '100%' };

  return (
    <Space.Compact style={containerStyle}>
      <Select
        showSearch
        value={value}
        onChange={onChange}
        loading={loading}
        placeholder={placeholder || `选择${kindLabel}`}
        style={{ width: '100%', minWidth: 0 }}
        optionFilterProp="label"
        filterOption={(input, option) => {
          const s = input.toLowerCase();
          return (option?.value as string)?.toLowerCase().includes(s)
            || (option?.label as string)?.toLowerCase().includes(s);
        }}
        dropdownRender={(menu) => (
          <>
            {menu}
            {allowAdd && !adding && (
              <div style={{ padding: '8px', borderTop: '1px solid #f0f0f0' }}>
                <Button type="link" icon={<PlusOutlined />} onClick={() => setAdding(true)}>
                  添加新{kindLabel}
                </Button>
              </div>
            )}
            {allowAdd && adding && (
              <div style={{ padding: '8px', borderTop: '1px solid #f0f0f0' }}>
                <Space direction="vertical" style={{ width: '100%' }}>
                  <Input size="small" placeholder="地址 0x..." value={newAddr} onChange={(e) => setNewAddr(e.target.value)} />
                  <Input size="small" placeholder="备注（可选）" value={newLabel} onChange={(e) => setNewLabel(e.target.value)} />
                  <Space>
                    <Button size="small" type="primary" onClick={handleAdd}>确认</Button>
                    <Button size="small" onClick={() => setAdding(false)}>取消</Button>
                  </Space>
                </Space>
              </div>
            )}
          </>
        )}
        options={options.map((o) => ({
          value: o.address,
          label: o.label ? `${o.label} (${shortenAddress(o.address)})` : shortenAddress(o.address),
          title: `${o.address}${o.extra ? ' — ' + o.extra : ''}`,
        }))}
      />
    </Space.Compact>
  );
}
