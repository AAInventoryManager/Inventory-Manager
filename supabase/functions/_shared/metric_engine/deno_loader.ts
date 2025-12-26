import { parse } from 'https://deno.land/std@0.177.0/yaml/mod.ts';
import type { MetricDefinition } from './types.ts';

export async function loadMetricDefinitionsFromDirectory(
  directoryUrl: URL
): Promise<MetricDefinition[]> {
  const definitions: MetricDefinition[] = [];

  for await (const entry of Deno.readDir(directoryUrl)) {
    if (!entry.isFile) {
      continue;
    }
    if (!entry.name.endsWith('.yaml') && !entry.name.endsWith('.yml')) {
      continue;
    }
    const fileUrl = new URL(entry.name, directoryUrl);
    const raw = await Deno.readTextFile(fileUrl);
    const parsed = parse(raw) as MetricDefinition | null;
    if (parsed) {
      definitions.push(parsed);
    }
  }

  return definitions;
}
