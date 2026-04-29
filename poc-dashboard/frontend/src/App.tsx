import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import Dashboard from './pages/Dashboard';
import ValidatorList from './pages/validators/ValidatorList';
import ValidatorDetail from './pages/validators/ValidatorDetail';
import AddValidator from './pages/validators/AddValidator';
import UserSearch from './pages/users/UserSearch';
import UserDetail from './pages/users/UserDetail';
import ProxyStake from './pages/ProxyStake';
import DAppList from './pages/dapps/DAppList';
import DAppDetail from './pages/dapps/DAppDetail';
import System from './pages/System';
import Events from './pages/Events';
import Logs from './pages/Logs';
import { AddressBookProvider } from './contexts/AddressBookContext';

function App() {
  return (
    <AddressBookProvider>
      <Layout>
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/validators" element={<ValidatorList />} />
          <Route path="/validators/add" element={<AddValidator />} />
          <Route path="/validators/:address" element={<ValidatorDetail />} />
          <Route path="/users" element={<UserSearch />} />
          <Route path="/users/:address" element={<UserDetail />} />
          <Route path="/proxy-stake" element={<ProxyStake />} />
          <Route path="/dapps" element={<DAppList />} />
          <Route path="/dapps/:admin" element={<DAppDetail />} />
          <Route path="/system" element={<System />} />
          <Route path="/events" element={<Events />} />
          <Route path="/logs" element={<Logs />} />
        </Routes>
      </Layout>
    </AddressBookProvider>
  );
}

export default App;
