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
