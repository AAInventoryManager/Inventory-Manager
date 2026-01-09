import { createClient, SupabaseClient } from '@supabase/supabase-js';
import './load-test-env';
import { TEST_USERS } from '../fixtures/users';
import { TEST_COMPANIES } from '../fixtures/companies';

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

export const SUPABASE_URL = requireEnv('SUPABASE_URL');
export const SUPABASE_ANON_KEY = requireEnv('SUPABASE_ANON_KEY');
export const SUPABASE_SERVICE_ROLE_KEY = requireEnv('SUPABASE_SERVICE_ROLE_KEY');
export const TEST_PASSWORD = process.env.TEST_USER_PASSWORD || 'TestPassword123!';

export { TEST_USERS, TEST_COMPANIES };

export const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

const AUTH_THROTTLE_MS = Number(
  process.env.AUTH_THROTTLE_MS || (process.env.CI ? '1500' : '0')
);
let authQueue = Promise.resolve();
let lastAuthAt = 0;

function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function withAuthThrottle<T>(fn: () => Promise<T>): Promise<T> {
  const run = async () => {
    if (AUTH_THROTTLE_MS > 0) {
      const waitMs = Math.max(0, AUTH_THROTTLE_MS - (Date.now() - lastAuthAt));
      if (waitMs > 0) await sleep(waitMs);
      lastAuthAt = Date.now();
    }
    return fn();
  };
  authQueue = authQueue.then(run, run);
  return authQueue;
}

function isRetryableAuthError(error: { message?: string; status?: number; code?: string } | null): boolean {
  if (!error) return false;
  // 429 is explicit rate limit
  if (error.status === 429) return true;
  // 500 errors can happen when Supabase is overloaded
  if (error.status === 500) return true;
  // Check error codes that indicate temporary failures
  if (error.code === 'unexpected_failure') return true;
  const message = String(error.message || '').toLowerCase();
  return message.includes('rate limit');
}

function createAuthStorageKey(seed: string): string {
  const suffix = Math.random().toString(16).slice(2);
  return `sb-test-${seed.replace(/[^a-z0-9]/gi, '-')}-${Date.now()}-${suffix}`;
}

function createMemoryStorage() {
  const store = new Map<string, string>();
  return {
    getItem: (key: string) => (store.has(key) ? store.get(key)! : null),
    setItem: (key: string, value: string) => {
      store.set(key, value);
    },
    removeItem: (key: string) => {
      store.delete(key);
    }
  };
}

export async function createAuthenticatedClient(email: string, password: string): Promise<SupabaseClient> {
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      storageKey: createAuthStorageKey(email),
      storage: createMemoryStorage()
    }
  });

  const maxAttempts = AUTH_THROTTLE_MS > 0 ? 5 : 2;
  let lastError: { message?: string } | null = null;
  let data: { session: any } | null = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const result = await withAuthThrottle(() => client.auth.signInWithPassword({ email, password }));
    data = result.data;
    if (!result.error) break;
    lastError = result.error;
    if (!isRetryableAuthError(result.error) || attempt === maxAttempts) {
      break;
    }
    await sleep(1000 * attempt);
  }
  if (lastError) throw new Error(`Failed to authenticate ${email}: ${lastError.message}`);
  if (!data?.session) throw new Error(`No session returned for ${email}`);
  return client;
}

let clientCache: Record<string, SupabaseClient> = {};

export async function getClient(userType: keyof typeof TEST_USERS): Promise<SupabaseClient> {
  if (!clientCache[userType]) {
    clientCache[userType] = await createAuthenticatedClient(TEST_USERS[userType], TEST_PASSWORD);
  }
  return clientCache[userType];
}

export function clearClientCache() {
  clientCache = {};
}

export async function getCompanyId(slug: string): Promise<string> {
  const { data, error } = await adminClient
    .from('companies')
    .select('id')
    .eq('slug', slug)
    .single();
  if (error || !data) throw new Error(`Company not found for slug: ${slug}`);
  return data.id;
}

export async function getUserIdByEmail(email: string): Promise<string> {
  const { data, error } = await adminClient
    .from('profiles')
    .select('user_id')
    .eq('email', email)
    .single();
  if (error || !data) throw new Error(`User not found for email: ${email}`);
  return data.user_id;
}

export async function getAuthUserIdByEmail(email: string): Promise<string> {
  // Paginated lookup to handle large user lists with retry for transient errors
  const maxAttempts = 3;
  let lastError: { message?: string; status?: number; code?: string } | null = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let page = 1;
    while (page <= 10) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) {
        lastError = error;
        if (isRetryableAuthError(error) && attempt < maxAttempts) {
          await sleep(1000 * attempt);
          break; // Break inner loop to retry from page 1
        }
        throw error;
      }
      const user = data.users.find(u => u.email === email);
      if (user) return user.id;
      if (!data.users.length || data.users.length < 1000) {
        // Reached end without finding user
        throw new Error(`Auth user not found for email: ${email}`);
      }
      page++;
    }
    // If we broke out of inner loop due to retryable error, continue outer loop
    if (lastError && isRetryableAuthError(lastError) && attempt < maxAttempts) {
      continue;
    }
    break;
  }
  throw new Error(`Auth user not found for email: ${email}`);
}

export type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

function isMissingRelation(error: { code?: string; message?: string } | null): boolean {
  if (!error) return false;
  if (error.code === '42P01' || error.code === 'PGRST205') return true;
  const message = String(error.message || '');
  return message.includes('does not exist') || message.includes('relation') || message.includes('Could not find the table');
}

async function setCompanyTierViaSettings(companyId: string, tier: Tier): Promise<void> {
  const { data, error } = await adminClient
    .from('companies')
    .select('settings')
    .eq('id', companyId)
    .single();
  if (error || !data) throw error || new Error('Failed to load company settings');
  const settings =
    data.settings && typeof data.settings === 'object' && !Array.isArray(data.settings)
      ? data.settings
      : {};
  const nextSettings = { ...settings, tier };
  const { error: updateError } = await adminClient
    .from('companies')
    .update({ settings: nextSettings, updated_at: new Date().toISOString() })
    .eq('id', companyId);
  if (updateError) throw updateError;
}

async function setCompanyTierViaBilling(companyId: string, tier: Tier): Promise<boolean> {
  const { error: deleteError } = await adminClient
    .from('billing_subscriptions')
    .delete()
    .eq('company_id', companyId);
  if (deleteError && isMissingRelation(deleteError)) return false;
  if (deleteError) throw deleteError;

  if (tier === 'starter') {
    return true;
  }

  const priceId = `test_${tier}_${Date.now()}`;
  const { error: priceError } = await adminClient
    .from('billing_price_map')
    .upsert({ provider: 'stripe', price_id: priceId, tier, is_active: true }, { onConflict: 'provider,price_id' });
  if (priceError && isMissingRelation(priceError)) return false;
  if (priceError) throw priceError;

  const { error: insertError } = await adminClient.from('billing_subscriptions').insert({
    company_id: companyId,
    provider: 'stripe',
    price_id: priceId,
    status: 'active',
    provider_status: 'active',
    current_period_start: new Date().toISOString(),
    current_period_end: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString()
  });
  if (insertError && isMissingRelation(insertError)) return false;
  if (insertError) throw insertError;

  return true;
}

export async function setCompanyTierForTests(
  companyId: string,
  tier: Tier,
  reason?: string
): Promise<'base' | 'billing' | 'settings'> {
  const superAuth = await getClient('SUPER');
  try{
    await superAuth.rpc('revoke_company_tier_override', { p_company_id: companyId });
  }catch(_e){}
  const { data, error } = await superAuth.rpc('set_company_base_tier', {
    p_company_id: companyId,
    p_new_base_tier: tier
  });
  if (!error) {
    if (data && data.success === false) throw new Error(data.error || 'Base tier update failed');
    return 'base';
  }
  if (error.code !== 'PGRST202') throw error;

  const appliedViaBilling = await setCompanyTierViaBilling(companyId, tier);
  if (!appliedViaBilling) {
    await setCompanyTierViaSettings(companyId, tier);
    return 'settings';
  }
  return 'billing';
}
