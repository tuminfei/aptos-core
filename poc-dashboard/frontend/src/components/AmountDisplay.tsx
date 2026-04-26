import { Tooltip } from 'antd';
import { formatTopo, formatNumber } from '../utils/format';

interface Props {
  octas: number;
}

export default function AmountDisplay({ octas }: Props) {
  return (
    <Tooltip title={`${formatNumber(octas)} octas`}>
      <span>{formatTopo(octas)} TOPO</span>
    </Tooltip>
  );
}
