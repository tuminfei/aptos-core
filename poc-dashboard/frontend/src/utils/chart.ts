type ScaledValueAxisOptions = {
  values: number[];
  formatter: (value: number) => string;
  name?: string;
  position?: 'left' | 'right';
  minInterval?: number;
  minFloor?: number;
};

export function createScaledValueAxis({ values, formatter, name, position, minInterval, minFloor = 0 }: ScaledValueAxisOptions) {
  const finiteValues = values.filter((value) => Number.isFinite(value));
  const hasValues = finiteValues.length > 0;
  const min = hasValues ? Math.min(...finiteValues) : minFloor;
  const max = hasValues ? Math.max(...finiteValues) : minFloor;
  const range = max - min;
  const maxAbs = Math.max(Math.abs(min), Math.abs(max), Number.EPSILON);
  const rangePadding = range > 0 ? range * 0.08 : maxAbs * 0.05;
  const padding = Math.max(minInterval || 0, rangePadding, Number.EPSILON);
  const axisMin = Math.max(minFloor, min - padding);
  const axisMax = max + padding;

  return {
    type: 'value' as const,
    name,
    position,
    min: axisMin,
    max: axisMax,
    scale: true,
    minInterval,
    splitLine: { show: position !== 'right' },
    axisLabel: {
      formatter,
      showMinLabel: true,
      showMaxLabel: true,
    },
  };
}
