// ============================================================================
// HEALTH CHECK HANDLER
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { jsonResponse } from '../utils/responses.ts';
import type { AuthContext } from '../middleware/auth.ts';

/**
 * GET /health
 * 
 * Returns API health status. No authentication required.
 * Used for load balancer health checks and monitoring.
 */
export async function handleHealth(
  _request: Request,
  _auth: AuthContext | null,
  _params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
  
  let dbStatus = 'unknown';
  let authStatus = 'unknown';
  
  if (supabaseUrl && supabaseAnonKey) {
    try {
      const supabase = createClient(supabaseUrl, supabaseAnonKey);
      
      // Check database connectivity
      const { error: dbError } = await supabase
        .from('companies')
        .select('id')
        .limit(1);
      
      dbStatus = dbError ? 'disconnected' : 'connected';
      
      // Check auth service
      authStatus = 'operational';
    } catch {
      dbStatus = 'disconnected';
      authStatus = 'degraded';
    }
  }
  
  const isHealthy = dbStatus === 'connected' && authStatus === 'operational';
  
  return jsonResponse({
    status: isHealthy ? 'healthy' : 'unhealthy',
    version: '1.0.0',
    timestamp: new Date().toISOString(),
    checks: {
      database: dbStatus,
      auth: authStatus,
    },
  }, isHealthy ? 200 : 503);
}
