import { beforeAll, describe, expect, it } from 'vitest';
import path from 'node:path';

import { loadMetricDefinitionsFromDirectory } from '../../supabase/functions/_shared/metric_engine/node_loader.ts';
import { MetricRegistry } from '../../supabase/functions/_shared/metric_engine/registry.ts';
import { MetricExecutionService } from '../../supabase/functions/_shared/metric_engine/engine.ts';
import { UnauthorizedTier } from '../../supabase/functions/_shared/metric_engine/errors.ts';
import type { MetricDefinition } from '../../supabase/functions/_shared/metric_engine/types.ts';

const definitionsPath = path.join(
  process.cwd(),
  'supabase',
  'functions',
  '_shared',
  'metric_engine',
  'definitions'
);

let service: MetricExecutionService;
let definitions: MetricDefinition[] = [];

function getMetric(metricId: string): MetricDefinition {
  const metric = definitions.find((definition) => definition.metric_id === metricId);
  if (!metric) {
    throw new Error(`${metricId} definition not found`);
  }
  return metric;
}

beforeAll(async () => {
  definitions = await loadMetricDefinitionsFromDirectory(definitionsPath);
  const registry = new MetricRegistry(definitions);
  service = new MetricExecutionService(registry);
});

describe('MetricExecutionService - Inventory Turnover', () => {
  let metric: MetricDefinition;

  beforeAll(() => {
    metric = getMetric('INVENTORY_TURNOVER');
  });

  it('executes governed test cases from YAML', () => {
    if (!metric.tests || metric.tests.length === 0) {
      throw new Error('No test cases defined for INVENTORY_TURNOVER');
    }

    for (const testCase of metric.tests) {
      const result = service.execute({
        metric_id: metric.metric_id,
        requesting_user_tier: 'TIER_3',
        context: {
          period_start: '2025-01-01',
          period_end: '2025-01-31',
        },
        inputs: testCase.inputs,
      });

      if (testCase.expected_output === null) {
        expect(result.value).toBeNull();
      } else {
        expect(result.value).toBe(Number(testCase.expected_output));
      }
    }
  });

  it('blocks execution when tier is insufficient', () => {
    const testCase = metric.tests?.[0];
    if (!testCase) {
      throw new Error('Missing test case inputs for tier check');
    }

    expect(() =>
      service.execute({
        metric_id: metric.metric_id,
        requesting_user_tier: 'TIER_1',
        context: {
          period_start: '2025-01-01',
          period_end: '2025-01-31',
        },
        inputs: testCase.inputs,
      })
    ).toThrow(UnauthorizedTier);
  });
});

describe('MetricExecutionService - Fast/Slow/Dead Stock', () => {
  let metric: MetricDefinition;

  beforeAll(() => {
    metric = getMetric('FAST_SLOW_DEAD_STOCK');
  });

  it('classifies fast movement', () => {
    const result = service.execute({
      metric_id: metric.metric_id,
      requesting_user_tier: 'TIER_3',
      context: {
        period_start: '2025-01-01',
        period_end: '2025-01-31',
      },
      inputs: {
        QuantityMoved: 30,
        DaysObserved: 30,
      },
    });

    expect(result.value).toBe('FAST');
  });

  it('classifies slow movement', () => {
    const result = service.execute({
      metric_id: metric.metric_id,
      requesting_user_tier: 'TIER_3',
      context: {
        period_start: '2025-01-01',
        period_end: '2025-01-31',
      },
      inputs: {
        QuantityMoved: 2,
        DaysObserved: 30,
      },
    });

    expect(result.value).toBe('SLOW');
  });

  it('classifies dead movement', () => {
    const result = service.execute({
      metric_id: metric.metric_id,
      requesting_user_tier: 'TIER_3',
      context: {
        period_start: '2025-01-01',
        period_end: '2025-01-31',
      },
      inputs: {
        QuantityMoved: 0,
        DaysObserved: 30,
      },
    });

    expect(result.value).toBe('DEAD');
  });
});

describe('MetricExecutionService - ABC Classification', () => {
  let metric: MetricDefinition;

  beforeAll(() => {
    metric = getMetric('ABC_CLASSIFICATION');
  });

  it('executes governed test cases from YAML', () => {
    if (!metric.tests || metric.tests.length === 0) {
      throw new Error('No test cases defined for ABC_CLASSIFICATION');
    }

    for (const testCase of metric.tests) {
      const result = service.execute({
        metric_id: metric.metric_id,
        requesting_user_tier: 'TIER_3',
        context: {
          period_start: '2025-01-01',
          period_end: '2025-12-31',
        },
        inputs: testCase.inputs,
      });

      expect(result.value).toEqual(testCase.expected_output);
    }
  });
});
