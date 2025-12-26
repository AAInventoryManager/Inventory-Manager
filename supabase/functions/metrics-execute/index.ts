import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

import { MetricExecutionService } from '../_shared/metric_engine/engine.ts';
import { loadMetricDefinitionsFromDirectory } from '../_shared/metric_engine/deno_loader.ts';
import { MetricRegistry } from '../_shared/metric_engine/registry.ts';
import { handleMetricsExecuteRequest } from './handler.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const definitionsUrl = new URL('../_shared/metric_engine/definitions/', import.meta.url);
const registry = new MetricRegistry(await loadMetricDefinitionsFromDirectory(definitionsUrl));
const metricService = new MetricExecutionService(registry);

serve(async (req) => {
  return handleMetricsExecuteRequest(req, {
    metricService,
    getUser: getUserFromRequest,
    corsHeaders,
  });
});

function getSupabaseClient(token: string) {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') || '';
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error('Missing Supabase configuration');
  }

  return createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: { Authorization: `Bearer ${token}` },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

function extractAuthToken(req: Request): string | null {
  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader.startsWith('Bearer ')) {
    return null;
  }
  const token = authHeader.slice(7).trim();
  return token || null;
}

async function getUserFromRequest(req: Request) {
  const token = extractAuthToken(req);
  if (!token) {
    return { user: null, error: 'Unauthorized' };
  }

  const supabase = getSupabaseClient(token);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user) {
    return { user: null, error: 'Unauthorized' };
  }

  let isSuperUser = false;
  try {
    const { data: superUserFlag, error: superUserError } = await supabase.rpc('is_super_user');
    if (!superUserError) {
      isSuperUser = superUserFlag === true;
    }
  } catch (_error) {
    isSuperUser = false;
  }

  return { user: data.user, is_super_user: isSuperUser };
}
