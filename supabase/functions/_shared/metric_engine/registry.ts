import type { MetricDefinition } from './types.ts';

export class MetricRegistry {
  private definitions: Map<string, MetricDefinition>;

  constructor(definitions: MetricDefinition[]) {
    this.definitions = new Map();
    for (const definition of definitions) {
      this.definitions.set(definition.metric_id, definition);
    }
  }

  get(metricId: string): MetricDefinition | null {
    return this.definitions.get(metricId) ?? null;
  }
}
