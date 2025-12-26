import type { MetricExecutionRequest, Tier } from '../_shared/metric_engine/types.ts';
import type { MetricExecutionService } from '../_shared/metric_engine/engine.ts';
import type { MetricRegistry } from '../_shared/metric_engine/registry.ts';
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
}

export interface MetricsPreviewDependencies {
  metricService: MetricExecutionService;
  registry: MetricRegistry;
  getUser: (req: Request) => Promise<AuthResult>;
  corsHeaders?: Record<string, string>;
}

const allowedTiers: Tier[] = ['TIER_1', 'TIER_2', 'TIER_3'];
const tierRank: Record<Tier, number> = {
  TIER_1: 1,
  TIER_2: 2,
  TIER_3: 3,
};

export async function handleMetricsPreviewRequest(
  req: Request,
  deps: MetricsPreviewDependencies
): Promise<Response> {
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

  const { user, error, is_super_user } = await deps.getUser(req);
  if (error || !user) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'Unauthorized', message: 'Unauthorized' } }),
      { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  if (is_super_user !== true) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'Unauthorized', message: 'Super user access required' } }),
      { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const metric_id = typeof body.metric_id === 'string' ? body.metric_id : '';
  const context = (body.context ?? {}) as MetricExecutionRequest['context'];
  const inputs = (body.inputs ?? {}) as MetricExecutionRequest['inputs'];
  const simulateTierRaw = typeof body.simulate_tier === 'string' ? body.simulate_tier : '';
  const simulateTier = simulateTierRaw ? simulateTierRaw.trim().toUpperCase() : '';

  if (!metric_id) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'MissingRequiredInputs', message: 'metric_id is required' } }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const metric = deps.registry.get(metric_id);
  if (!metric) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'MetricNotFound', message: `Metric not found: ${metric_id}` } }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  if (simulateTier && !allowedTiers.includes(simulateTier as Tier)) {
    return new Response(
      JSON.stringify({ ok: false, error: { code: 'InvalidTier', message: 'Invalid simulate_tier' } }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const requesting_user_tier =
    (simulateTier as Tier) ||
    (typeof user.app_metadata?.tier === 'string' ? (user.app_metadata.tier as Tier) : 'TIER_3');

  const tierEvaluation = {
    required_tier: metric.tier,
    requesting_user_tier,
    authorized: isTierAuthorized(requesting_user_tier, metric.tier),
  };

  if (!tierEvaluation.authorized) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: { code: 'UnauthorizedTier', message: 'Tier is insufficient for this metric' },
        tier_evaluation: tierEvaluation,
      }),
      { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    const result = deps.metricService.execute({
      metric_id,
      requesting_user_tier: requesting_user_tier as MetricExecutionRequest['requesting_user_tier'],
      context,
      inputs,
    });
    return new Response(
      JSON.stringify({ ok: true, data: result, tier_evaluation: tierEvaluation }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (errorThrown) {
    const status = statusForMetricError(errorThrown);
    const code = errorThrown instanceof Error ? errorThrown.name : 'UnknownError';
    const message =
      errorThrown instanceof Error ? errorThrown.message : 'Metric preview failed';
    return new Response(
      JSON.stringify({ ok: false, error: { code, message }, tier_evaluation: tierEvaluation }),
      { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

function isTierAuthorized(requested: Tier, required: Tier): boolean {
  const requestedRank = tierRank[requested];
  const requiredRank = tierRank[required];
  if (!requestedRank || !requiredRank) {
    return false;
  }
  return requestedRank >= requiredRank;
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
