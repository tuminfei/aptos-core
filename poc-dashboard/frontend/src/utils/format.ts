export function shortenAddress(addr: string, chars = 6): string {
  if (!addr) return '';
  if (addr.length <= chars * 2 + 2) return addr;
  return `${addr.slice(0, chars + 2)}...${addr.slice(-chars)}`;
}

export function octasToTopo(octas: number | string): number {
  return Number(octas) / 1e8;
}

export function topoToOctas(topo: number | string): number {
  return Math.floor(Number(topo) * 1e8);
}

export function formatNumber(n: number | string): string {
  return Number(n).toLocaleString();
}

const SUPERSCRIPT_DIGITS: Record<string, string> = {
  '-': '⁻',
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
};

function formatSuperscriptExponent(exponent: number): string {
  return String(exponent).split('').map((char) => SUPERSCRIPT_DIGITS[char] || char).join('');
}

export function formatCompactNumber(n: number | string): string {
  const value = Number(n || 0);
  if (!Number.isFinite(value) || value === 0) return '0';

  const abs = Math.abs(value);
  if (abs < 10_000) {
    return value.toLocaleString(undefined, { maximumFractionDigits: abs >= 100 ? 0 : 2 });
  }

  const exponent = Math.floor(Math.log10(abs));
  const coefficient = value / Math.pow(10, exponent);
  return `${coefficient.toLocaleString(undefined, { maximumFractionDigits: 2 })}x10${formatSuperscriptExponent(exponent)}`;
}

export function formatTopo(octas: number | string): string {
  return octasToTopo(octas).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export function formatRewardAmount(octas: number | string): string {
  const amount = Number(octas || 0);
  if (!Number.isFinite(amount) || amount === 0) return '0 TOPO';
  const topo = amount / 1e8;
  if (Math.abs(topo) >= 0.0001) {
    return `${topo.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 6 })} TOPO`;
  }
  return `${Math.trunc(amount).toLocaleString()} octas`;
}

export function formatPercent(bps: number): string {
  return (bps / 100).toFixed(1) + '%';
}

export function formatRewardRate(rate: { bps?: number; numerator?: number | string; denominator?: number | string } | undefined): string {
  if (!rate) return '0%';
  const numerator = Number(rate.numerator || 0);
  const denominator = Number(rate.denominator || 0);
  if (numerator > 0 && denominator > 0) {
    const percent = (numerator / denominator) * 100;
    if (percent === 0) return '0%';
    if (Math.abs(percent) < 0.000001) return `${percent.toExponential(2)}%`;
    return `${percent.toLocaleString(undefined, { maximumFractionDigits: 6 })}%`;
  }
  return formatPercent(rate.bps || 0);
}

export function formatTimestamp(ts: string | number): string {
  if (!ts) return '-';
  if (typeof ts === 'string' && /[-T:]/.test(ts)) {
    const normalized = ts.includes('T') ? ts : ts.replace(' ', 'T');
    const date = new Date(normalized);
    if (!Number.isNaN(date.getTime())) return date.toLocaleString();
  }
  const n = typeof ts === 'string' ? parseInt(ts) : ts;
  if (n > 1e15) return new Date(n / 1000).toLocaleString();
  if (n > 1e12) return new Date(n).toLocaleString();
  return new Date(n * 1000).toLocaleString();
}
