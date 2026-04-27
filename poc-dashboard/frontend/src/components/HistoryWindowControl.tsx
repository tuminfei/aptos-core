import { Button, Select, Space, Typography } from 'antd';

const { Text } = Typography;

export const HISTORY_LIMIT_OPTIONS = [50, 200, 500, 1000];

type Props = {
  limit: number;
  offset: number;
  total?: number;
  shown?: number;
  onLimitChange: (limit: number) => void;
  onOffsetChange: (offset: number) => void;
};

export default function HistoryWindowControl({
  limit,
  offset,
  total = 0,
  shown = 0,
  onLimitChange,
  onOffsetChange,
}: Props) {
  const rangeStart = shown > 0 ? offset + 1 : 0;
  const rangeEnd = offset + shown;
  const hasNewer = offset > 0;
  const hasOlder = rangeEnd < total;

  const handleLimitChange = (nextLimit: number) => {
    onLimitChange(nextLimit);
    onOffsetChange(0);
  };

  return (
    <Space size={8} wrap>
      <Text type="secondary">显示 {rangeStart}-{rangeEnd} / {total} 条</Text>
      <Select
        size="small"
        value={limit}
        onChange={handleLimitChange}
        style={{ width: 112 }}
        options={HISTORY_LIMIT_OPTIONS.map((value) => ({ value, label: `最近 ${value}` }))}
      />
      <Button size="small" disabled={!hasOlder} onClick={() => onOffsetChange(offset + limit)}>更早</Button>
      <Button size="small" disabled={!hasNewer} onClick={() => onOffsetChange(Math.max(0, offset - limit))}>更新</Button>
      <Button size="small" disabled={!hasNewer} onClick={() => onOffsetChange(0)}>最新</Button>
    </Space>
  );
}
