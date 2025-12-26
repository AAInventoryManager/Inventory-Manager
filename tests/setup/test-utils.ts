import { createClient, SupabaseClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import { TEST_USERS } from '../fixtures/users';
import { TEST_COMPANIES } from '../fixtures/companies';

const envPath = process.env.ENV_PATH || (process.env.CI ? '.env.test.ci' : '.env.test');
dotenv.config({ path: envPath });

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

export async function createAuthenticatedClient(email: string, password: string): Promise<SupabaseClient> {
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const { data, error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`Failed to authenticate ${email}: ${error.message}`);
  if (!data.session) throw new Error(`No session returned for ${email}`);
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
  const { data, error } = await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (error) throw error;
  const user = data.users.find(u => u.email === email);
  if (!user) throw new Error(`Auth user not found for email: ${email}`);
  return user.id;
}

export type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

function isMissingRelation(error: { code?: string; message?: string } | null): boolean {
  if (!error) return false;
  if (error.code === '42P01') return true;
  const message = String(error.message || '');
  return message.includes('does not exist') || message.includes('relation');
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
): Promise<'override' | 'billing' | 'settings'> {
  const superAuth = await getClient('SUPER');
  const overrideTier = tier === 'starter' ? null : tier;
  const { data, error } = await superAuth.rpc('set_company_tier_override', {
    p_company_id: companyId,
    p_tier: overrideTier,
    p_reason: reason || `Test tier override: ${tier}`
  });
  if (!error) {
    if (data && data.success === false) throw new Error(data.error || 'Tier override failed');
    return 'override';
  }
  if (error.code !== 'PGRST202') throw error;

  const appliedViaBilling = await setCompanyTierViaBilling(companyId, tier);
  if (!appliedViaBilling) {
    await setCompanyTierViaSettings(companyId, tier);
    return 'settings';
  }
  return 'billing';
}
