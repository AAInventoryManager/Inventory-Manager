import type { MetricExecutionRequest } from '../_shared/metric_engine/types.ts';
import type { MetricExecutionService } from '../_shared/metric_engine/engine.ts';
import {
  InvalidTimeContext,
  MetricNotFound,
  MissingRequiredInputs,
  UnauthorizedTier,
} from '../_shared/metric_engine/errors.ts';

export interface AuthenticatedUser {
  app_metadata?: Record<string, unknown>;
}

export interface AuthResult {
  user: AuthenticatedUser | null;
  error?: string;
  is_super_user?: boolean;
  effective_company_tier?: string | null;
}

export interface MetricsExecuteDependencies {
  metricService: MetricExecutionService;
  getUser: (req: Request) => Promise<AuthResult>;
  corsHeaders?: Record<string, string>;
}

export async function handleMetricsExecuteRequest(
  req: Request,
  deps: MetricsExecuteDependencies
): Promise<Response> {
  // Tier enforcement MUST route through DB-backed entitlement checks.
  // JWT tier claims are not authoritative on their own; never trust client-provided tiers.
  const corsHeaders = deps.corsHeaders ?? {};

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'MethodNotAllowed', message: 'Method not allowed' } }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  let body: Record<string, unknown>;

  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch (_error) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'InvalidJSON', message: 'Invalid JSON body' } }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const { user, error, is_super_user, effective_company_tier } = await deps.getUser(req);
  if (error || !user) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'Unauthorized', message: 'Unauthorized' } }),
      { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const requesting_user_tier = mapCompanyTierToMetricTier(effective_company_tier);
  if (!requesting_user_tier) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'UnauthorizedTier', message: 'No effective tier available' } }),
      { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const metric_id = typeof body.metric_id === 'string' ? body.metric_id : '';
  const context = (body.context ?? {}) as MetricExecutionRequest['context'];
  const inputs = (body.inputs ?? {}) as MetricExecutionRequest['inputs'];

  try {
    const result = deps.metricService.execute({
      metric_id,
      requesting_user_tier: requesting_user_tier as MetricExecutionRequest['requesting_user_tier'],
      context,
      inputs,
    });
    return new Response(JSON.stringify({ ok: true, data: result }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (errorThrown) {
    const status = statusForMetricError(errorThrown);
    const code = errorThrown instanceof Error ? errorThrown.name : 'UnknownError';
    const message =
      errorThrown instanceof Error ? errorThrown.message : 'Metric execution failed';
    return new Response(JSON.stringify({ ok: false, error: { code, message } }), {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
}

function mapCompanyTierToMetricTier(
  tier: string | null | undefined
): MetricExecutionRequest['requesting_user_tier'] | null {
  const normalized = String(tier || '').trim().toLowerCase();
  if (!normalized) return null;
  if (normalized === 'starter') return 'TIER_1';
  if (normalized === 'professional' || normalized === 'business') return 'TIER_2';
  if (normalized === 'enterprise') return 'TIER_3';
  return null;
}

function statusForMetricError(error: unknown): number {
  if (error instanceof MetricNotFound) {
    return 404;
  }
  if (error instanceof UnauthorizedTier) {
    return 403;
  }
  if (error instanceof InvalidTimeContext) {
    return 400;
  }
  if (error instanceof MissingRequiredInputs) {
    return 400;
  }
  return 500;
}
