import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  setCompanyTierForTests,
  TEST_PASSWORD,
  TEST_USERS
} from '../../setup/test-utils';

type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

async function createTestUser(email: string): Promise<string> {
  const { data, error } = await adminClient.auth.admin.createUser({
    email,
    password: TEST_PASSWORD,
    email_confirm: true
  });
  let userId = data?.user?.id;
  if (!userId) {
    if (error && error.message.toLowerCase().includes('already')) {
      userId = await getAuthUserIdByEmail(email);
    } else if (error) {
      throw error;
    }
  }
  if (!userId) throw new Error('Failed to create user');

  const { error: updateError } = await adminClient.auth.admin.updateUserById(userId, {
    password: TEST_PASSWORD,
    email_confirm: true
  });
  if (updateError) throw updateError;

  return userId;
}

describe('Tier overrides and super user bypass', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let superAuth: SupabaseClient;
  let adminUserId: string;
  let superUserId: string;

  beforeAll(async () => {
    const slug = `tier-override-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({ name: 'Tier Override Test', slug, settings: { test: true } })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = `tier-admin+${uniqueSuffix}@test.local`;
    adminUserId = await createTestUser(adminEmail);

    const { error: memberInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (memberInsertError) throw memberInsertError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    superAuth = await getClient('SUPER');
    superUserId = await getAuthUserIdByEmail(TEST_USERS.SUPER);

    await setCompanyTierForTests(companyId, 'starter', 'Reset tier for test setup');
  });

  it('allows super user access with no subscription while blocking non-super users', async () => {
    await setCompanyTierForTests(companyId, 'starter', 'Ensure starter baseline');

    const { error: denied } = await adminAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(denied).not.toBeNull();

    const { error: allowed } = await superAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(allowed).toBeNull();
  });

  it('keeps starter subscriptions restricted for non-super users', async () => {
    await setCompanyTierForTests(companyId, 'starter', 'Ensure starter baseline');

    const { error: denied } = await adminAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(denied).not.toBeNull();

    const { error: allowed } = await superAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(allowed).toBeNull();
  });

  it('applies overrides, records audit fields, and reverts on clear', async () => {
    const method = await setCompanyTierForTests(companyId, 'enterprise', 'Enterprise override for test');

    if (method === 'override') {
      const { data: companyRow, error: companyError } = await adminClient
        .from('companies')
        .select('tier_override,tier_override_reason,tier_override_set_by,tier_override_set_at')
        .eq('id', companyId)
        .single();
      expect(companyError).toBeNull();
      expect(companyRow?.tier_override).toBe('enterprise');
      expect(companyRow?.tier_override_reason).toBe('Enterprise override for test');
      expect(companyRow?.tier_override_set_by).toBe(superUserId);
      expect(companyRow?.tier_override_set_at).toBeTruthy();
    }

    const { error: allowed } = await adminAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(allowed).toBeNull();

    await setCompanyTierForTests(companyId, 'starter', 'Clear override for test');

    const { error: denied } = await adminAuth.rpc('get_audit_log', {
      p_company_id: companyId,
      p_limit: 5,
      p_offset: 0
    });
    expect(denied).not.toBeNull();
  });
});
