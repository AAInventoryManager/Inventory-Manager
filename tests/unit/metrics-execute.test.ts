import { beforeAll, describe, expect, it } from 'vitest';
import path from 'node:path';

import { handleMetricsExecuteRequest } from '../../supabase/functions/metrics-execute/handler.ts';
import { loadMetricDefinitionsFromDirectory } from '../../supabase/functions/_shared/metric_engine/node_loader.ts';
import { MetricRegistry } from '../../supabase/functions/_shared/metric_engine/registry.ts';
import { MetricExecutionService } from '../../supabase/functions/_shared/metric_engine/engine.ts';
import type { MetricDefinition } from '../../supabase/functions/_shared/metric_engine/types.ts';

let metricService: MetricExecutionService;
let definitions: MetricDefinition[] = [];

beforeAll(async () => {
  const definitionsPath = path.join(
    process.cwd(),
    'supabase',
    'functions',
    '_shared',
    'metric_engine',
    'definitions'
  );
  definitions = await loadMetricDefinitionsFromDirectory(definitionsPath);
  const registry = new MetricRegistry(definitions);
  metricService = new MetricExecutionService(registry);
});

describe('metrics-execute handler', () => {
  it('denies when client forges an elevated tier', async () => {
    const request = new Request('http://localhost/functions/v1/metrics-execute', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        metric_id: 'INVENTORY_TURNOVER',
        requesting_user_tier: 'TIER_3',
        context: {
          period_start: '2025-01-01',
          period_end: '2025-01-31',
        },
        inputs: {
          COGS: 120000,
          InventoryBegin: 40000,
          InventoryEnd: 60000,
        },
      }),
    });

    const response = await handleMetricsExecuteRequest(request, {
      metricService,
      getUser: async () => ({ user: { app_metadata: { tier: 'TIER_3' } }, effective_company_tier: 'starter' }),
    });

    expect(response.status).toBe(403);
    const payload = (await response.json()) as {
      ok: boolean;
      error?: { code?: string; message?: string };
    };
    expect(payload.ok).toBe(false);
    expect(payload.error?.code).toBe('UnauthorizedTier');
  });

  it('allows super_user to bypass tier enforcement', async () => {
    const request = new Request('http://localhost/functions/v1/metrics-execute', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        metric_id: 'INVENTORY_TURNOVER',
        context: {
          period_start: '2025-01-01',
          period_end: '2025-01-31',
        },
        inputs: {
          COGS: 120000,
          InventoryBegin: 40000,
          InventoryEnd: 60000,
        },
      }),
    });

    const response = await handleMetricsExecuteRequest(request, {
      metricService,
      getUser: async () => ({
        user: { app_metadata: { tier: 'TIER_1' } },
        is_super_user: true,
        effective_company_tier: 'enterprise',
      }),
    });

    expect(response.status).toBe(200);
    const payload = (await response.json()) as {
      ok: boolean;
      data?: { metric_id?: string };
      error?: { code?: string; message?: string };
    };
    expect(payload.ok).toBe(true);
    expect(payload.data?.metric_id).toBe('INVENTORY_TURNOVER');
  });
});
