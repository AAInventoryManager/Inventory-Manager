import { promises as fs } from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';
import type { MetricDefinition } from './types.ts';

export async function loadMetricDefinitionsFromDirectory(
  directoryPath: string
): Promise<MetricDefinition[]> {
  const entries = await fs.readdir(directoryPath, { withFileTypes: true });
  const definitions: MetricDefinition[] = [];

  for (const entry of entries) {
    if (!entry.isFile()) {
      continue;
    }
    if (!entry.name.endsWith('.yaml') && !entry.name.endsWith('.yml')) {
      continue;
    }
    const filePath = path.join(directoryPath, entry.name);
    const raw = await fs.readFile(filePath, 'utf8');
    const parsed = parse(raw) as MetricDefinition | null;
    if (parsed) {
      definitions.push(parsed);
    }
  }

  return definitions;
}
