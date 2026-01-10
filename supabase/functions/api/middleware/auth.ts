// ============================================================================
// AUTHENTICATION MIDDLEWARE
// ============================================================================

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { AuthenticationError } from '../utils/errors.ts';
import { isValidUUID } from '../utils/validate.ts';

export interface AuthContext {
  user: {
    id: string;
    email: string;
    company_id: string;
    role?: string;
  };
  supabase: SupabaseClient;
  token: string;
}

async function fetchUserCompanyIds(supabase: SupabaseClient): Promise<string[]> {
  const { data, error } = await supabase.rpc('get_user_company_ids');
  if (error) {
    throw new AuthenticationError('Failed to verify company membership');
  }
  return Array.isArray(data) ? data.map((id) => String(id || '').trim()).filter(Boolean) : [];
}

/**
 * Extract and validate JWT from Authorization header.
 * Returns an authenticated Supabase client scoped to the user.
 */
export async function authenticate(request: Request): Promise<AuthContext> {
  const authHeader = request.headers.get('Authorization');
  
  if (!authHeader) {
    throw new AuthenticationError('Missing Authorization header');
  }
  
  if (!authHeader.startsWith('Bearer ')) {
    throw new AuthenticationError('Authorization header must use Bearer scheme');
  }
  
  const token = authHeader.slice(7).trim();
  
  if (!token) {
    throw new AuthenticationError('Missing JWT token');
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
  
  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error('Missing Supabase configuration');
  }

  // Create Supabase client with the user's JWT
  // This client will have RLS applied based on the token's claims
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  // Verify the token
  const { data: { user }, error } = await supabase.auth.getUser(token);
  
  if (error || !user) {
    throw new AuthenticationError('Invalid or expired JWT token');
  }

  // Resolve company_id from app_metadata or request header
  let companyId = user.app_metadata?.company_id ? String(user.app_metadata.company_id).trim() : '';
  const headerCompanyId = (request.headers.get('X-Company-Id') || '').trim();

  if (!companyId) {
    if (headerCompanyId) {
      if (!isValidUUID(headerCompanyId)) {
        throw new AuthenticationError('Invalid company ID');
      }
      const companyIds = await fetchUserCompanyIds(supabase);
      if (!companyIds.includes(headerCompanyId)) {
        throw new AuthenticationError('User is not associated with a company');
      }
      companyId = headerCompanyId;
    } else {
      const companyIds = await fetchUserCompanyIds(supabase);
      if (companyIds.length === 1) {
        companyId = companyIds[0];
      }
    }
  }

  if (!companyId) {
    throw new AuthenticationError('User is not associated with a company');
  }

  // Get user role from profile (optional, may not exist yet)
  const { data: profile } = await supabase
    .from('user_profiles')
    .select('role')
    .eq('id', user.id)
    .single();

  return {
    user: {
      id: user.id,
      email: user.email!,
      company_id: companyId,
      role: profile?.role || 'member',
    },
    supabase,
    token,
  };
}

/**
 * Authentication middleware wrapper
 */
export function withAuth<T>(
  handler: (request: Request, auth: AuthContext) => Promise<T>
): (request: Request) => Promise<T> {
  return async (request: Request) => {
    const auth = await authenticate(request);
    return handler(request, auth);
  };
}
