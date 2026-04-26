import React, { useState } from 'react';
import { Layout as AntLayout, Menu, Badge } from 'antd';
import {
  DashboardOutlined,
  TeamOutlined,
  UserOutlined,
  SwapOutlined,
  AppstoreOutlined,
  SettingOutlined,
  BellOutlined,
  FileTextOutlined,
} from '@ant-design/icons';
import { useNavigate, useLocation } from 'react-router-dom';
import { useWebSocket } from '../hooks/useWebSocket';

const { Sider, Header, Content, Footer } = AntLayout;

const menuItems = [
  { key: '/', icon: <DashboardOutlined />, label: '集群总览' },
  { key: '/validators', icon: <TeamOutlined />, label: '验证者' },
  { key: '/users', icon: <UserOutlined />, label: '用户中心' },
  { key: '/proxy-stake', icon: <SwapOutlined />, label: '代理质押' },
  { key: '/dapps', icon: <AppstoreOutlined />, label: 'DApp' },
  { key: '/system', icon: <SettingOutlined />, label: '系统管理' },
  { key: '/events', icon: <BellOutlined />, label: '事件' },
  { key: '/logs', icon: <FileTextOutlined />, label: '操作日志' },
];

export default function Layout({ children }: { children: React.ReactNode }) {
  const navigate = useNavigate();
  const location = useLocation();
  const { connected } = useWebSocket();
  const [collapsed, setCollapsed] = useState(false);

  const selectedKey = menuItems.find((m) => location.pathname === m.key)?.key
    || menuItems.find((m) => m.key !== '/' && location.pathname.startsWith(m.key))?.key
    || '/';

  return (
    <AntLayout style={{ minHeight: '100vh' }}>
      <Sider collapsible collapsed={collapsed} onCollapse={setCollapsed}>
        <div style={{ height: 32, margin: 16, color: '#fff', fontWeight: 'bold', fontSize: collapsed ? 12 : 16, textAlign: 'center', lineHeight: '32px' }}>
          {collapsed ? 'POC' : 'TOPO POC 管理'}
        </div>
        <Menu
          theme="dark"
          mode="inline"
          selectedKeys={[selectedKey]}
          items={menuItems}
          onClick={({ key }) => navigate(key)}
        />
      </Sider>
      <AntLayout>
        <Header style={{ background: '#fff', padding: '0 24px', display: 'flex', justifyContent: 'flex-end', alignItems: 'center' }}>
          <span style={{ fontSize: 14, color: '#666' }}>TOPO POC 集群管理仪表盘</span>
        </Header>
        <Content style={{ margin: 16, padding: 24, background: '#fff', borderRadius: 8, minHeight: 360 }}>
          {children}
        </Content>
        <Footer style={{ textAlign: 'center', padding: '8px 16px', fontSize: 12 }}>
          WebSocket: <Badge status={connected ? 'success' : 'error'} text={connected ? '已连接' : '未连接'} />
        </Footer>
      </AntLayout>
    </AntLayout>
  );
}
