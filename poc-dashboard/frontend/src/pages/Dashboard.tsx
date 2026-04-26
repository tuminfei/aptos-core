import { useCallback, useEffect, useState } from 'react';
import { Row, Col, Card, Statistic, Table, Tag } from 'antd';
import ReactECharts from 'echarts-for-react';
import { getOverview } from '../services/dashboard';
import { usePolling } from '../hooks/usePolling';
import { useWebSocket } from '../hooks/useWebSocket';
import { useNavigate } from 'react-router-dom';
import AddressTag from '../components/AddressTag';
import { formatNumber, formatPercent } from '../utils/format';

export default function Dashboard() {
  const navigate = useNavigate();
  const fetchOverview = useCallback(() => getOverview(), []);
  const { data, loading } = usePolling(fetchOverview, 10000);
  const { lastMessage } = useWebSocket();
  const [events, setEvents] = useState<{ time: string; type: string; detail: string }[]>([]);

  useEffect(() => {
    if (lastMessage) {
      setEvents((prev) => [
        { time: new Date().toLocaleTimeString(), type: lastMessage.type, detail: JSON.stringify(lastMessage.data) },
        ...prev.slice(0, 19),
      ]);
    }
  }, [lastMessage]);

  const chain = data?.chain || {};
  const validators = data?.validators || {};
  const power = data?.power || {};
  const staking = data?.staking || {};
  const summary = data?.active_validators_summary || [];

  const pieOption = {
    tooltip: { trigger: 'item' as const },
    series: [{
      type: 'pie',
      radius: ['40%', '70%'],
      data: summary.map((v: any) => ({ name: v.address?.slice(0, 10), value: v.voting_power })),
      label: { show: true, formatter: '{b}\n{d}%' },
    }],
  };

  const columns = [
    { title: '地址', dataIndex: 'address', render: (v: string) => <AddressTag address={v} /> },
    { title: '投票权', dataIndex: 'voting_power', render: formatNumber },
    { title: '委托者', dataIndex: 'delegator_count' },
    { title: '出块成功率', dataIndex: 'success_rate', render: (v: number) => `${(v * 100).toFixed(1)}%` },
  ];

  return (
    <div>
      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={6}><Card><Statistic title="当前 Epoch" value={chain.epoch || 0} suffix={`区块 ${chain.block_height || 0}`} /></Card></Col>
        <Col span={6}><Card><Statistic title="活跃验证者" value={`${validators.active || 0} / ${validators.total || 0}`} suffix={validators.pending_active ? `待加入: ${validators.pending_active}` : ''} /></Card></Col>
        <Col span={6}><Card><Statistic title="总质押算力" value={formatNumber(staking.total_staked_power || 0)} /></Card></Col>
        <Col span={6}><Card><Statistic title="算力周期" value={power.current_period || 0} suffix={`剩余 ${power.epochs_until_next_period || 0}E`} /></Card></Col>
      </Row>

      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={12}>
          <Card title="验证者投票权分布">
            <ReactECharts option={pieOption} style={{ height: 300 }} />
          </Card>
        </Col>
        <Col span={12}>
          <Card title="验证者快照">
            <Table
              dataSource={summary}
              columns={columns}
              rowKey="address"
              size="small"
              pagination={false}
              onRow={(r: any) => ({ onClick: () => navigate(`/validators/${r.address}`), style: { cursor: 'pointer' } })}
            />
          </Card>
        </Col>
      </Row>

      <Card title="实时事件流" size="small">
        {events.length === 0 ? <span style={{ color: '#999' }}>等待事件...</span> : (
          <div style={{ maxHeight: 200, overflow: 'auto' }}>
            {events.map((e, i) => (
              <div key={i} style={{ fontSize: 12, padding: '2px 0', borderBottom: '1px solid #f0f0f0' }}>
                <Tag>{e.time}</Tag> <Tag color="blue">{e.type}</Tag> {e.detail}
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
