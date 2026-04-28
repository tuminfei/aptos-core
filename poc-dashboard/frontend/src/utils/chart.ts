type ScaledValueAxisOptions = {
  values: number[];
  formatter: (value: number) => string;
  name?: string;
  minInterval?: number;
  minFloor?: number;
};

export function createScaledValueAxis({ values, formatter, name, minInterval, minFloor = 0 }: ScaledValueAxisOptions) {
  const finiteValues = values.filter((value) => Number.isFinite(value));
  const hasValues = finiteValues.length > 0;
  const min = hasValues ? Math.min(...finiteValues) : minFloor;
  const max = hasValues ? Math.max(...finiteValues) : minFloor;
  const range = max - min;
  const flatPadding = Math.max(minInterval || 0, Math.ceil(Math.max(Math.abs(max), 1) * 0.05), 1);
  const axisMin = hasValues && range > 0 ? Math.max(minFloor, min) : Math.max(minFloor, min - flatPadding);
  const axisMax = hasValues && range > 0 ? max : max + flatPadding;

  return {
    type: 'value' as const,
    name,
    min: axisMin,
    max: axisMax,
    scale: true,
    minInterval,
    axisLabel: {
      formatter,
      showMinLabel: true,
      showMaxLabel: true,
    },
  };
}
