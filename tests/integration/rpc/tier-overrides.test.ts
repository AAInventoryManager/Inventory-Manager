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

async function fetchEntitlementEvents(companyId: string, eventName: string, recordId?: string) {
  const query = adminClient
    .from('audit_log')
    .select('id,new_values,record_id,user_id,created_at')
    .eq('company_id', companyId)
    .eq('table_name', 'entitlement_events')
    .order('created_at', { ascending: false })
    .limit(50);
  if (recordId) {
    query.eq('record_id', recordId);
  }
  const { data, error } = await query;
  if (error) throw error;
  return (data || []).filter(row => row?.new_values?.event_name === eventName);
}

async function fetchEntitlementEvent(companyId: string, eventName: string) {
  const events = await fetchEntitlementEvents(companyId, eventName);
  return events[0] || null;
}

describe('Company tier overrides and enforcement', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let superAuth: SupabaseClient;
  let adminUserId: string;
  let superUserId: string;

  beforeAll(async () => {
    const slug = `tier-override-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({ name: 'Tier Override Test', slug, settings: { test: true }, company_type: 'test' })
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

  it('applies base tier when no override exists', async () => {
    await setCompanyTierForTests(companyId, 'business', 'Base tier set to business');
    const { data, error } = await adminClient.rpc('effective_company_tier', { p_company_id: companyId });
    expect(error).toBeNull();
    expect(String(data)).toBe('business');

    const event = await fetchEntitlementEvent(companyId, 'entitlement.company_tier.base_changed');
    expect(event).toBeTruthy();
    expect(event?.new_values?.new_effective_tier).toBe('business');
  });

  it('applies override tier while active', async () => {
    await setCompanyTierForTests(companyId, 'starter', 'Base tier reset to starter');
    const endsAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

    const { data, error } = await superAuth.rpc('grant_company_tier_override', {
      p_company_id: companyId,
      p_override_tier: 'enterprise',
      p_ends_at: endsAt
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(true);

    const { data: effective, error: effectiveError } = await adminClient.rpc('effective_company_tier', {
      p_company_id: companyId
    });
    expect(effectiveError).toBeNull();
    expect(String(effective)).toBe('enterprise');

    const event = await fetchEntitlementEvent(companyId, 'entitlement.company_tier.override_granted');
    expect(event).toBeTruthy();
    expect(event?.user_id).toBe(superUserId);
    expect(event?.new_values?.new_effective_tier).toBe('enterprise');
  });

  it('revokes override immediately and reverts to base tier', async () => {
    await setCompanyTierForTests(companyId, 'professional', 'Base tier set to professional');
    await superAuth.rpc('grant_company_tier_override', {
      p_company_id: companyId,
      p_override_tier: 'enterprise',
      p_ends_at: null
    });

    const { data: revokeData, error: revokeError } = await superAuth.rpc('revoke_company_tier_override', {
      p_company_id: companyId
    });
    expect(revokeError).toBeNull();
    expect(revokeData?.success).toBe(true);

    const { data: effective, error: effectiveError } = await adminClient.rpc('effective_company_tier', {
      p_company_id: companyId
    });
    expect(effectiveError).toBeNull();
    expect(String(effective)).toBe('professional');

    const event = await fetchEntitlementEvent(companyId, 'entitlement.company_tier.override_revoked');
    expect(event).toBeTruthy();
    expect(event?.new_values?.new_effective_tier).toBe('professional');
  });

  it('expires overrides automatically and logs expiration', async () => {
    await setCompanyTierForTests(companyId, 'starter', 'Base tier reset to starter');

    const expiredEnd = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const expiredStart = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();

    const { data: overrideRow, error: insertError } = await adminClient
      .from('company_tier_overrides')
      .insert({
        company_id: companyId,
        override_tier: 'business',
        starts_at: expiredStart,
        ends_at: expiredEnd,
        revoked_at: null,
        created_by: superUserId,
        created_at: expiredStart
      })
      .select('id')
      .single();
    expect(insertError).toBeNull();
    if (!overrideRow?.id) throw new Error('Failed to insert override');

    const { data: effective, error: effectiveError } = await adminClient.rpc('effective_company_tier', {
      p_company_id: companyId
    });
    expect(effectiveError).toBeNull();
    expect(String(effective)).toBe('starter');

    const { error: detailsError } = await superAuth.rpc('get_company_tier_details', {
      p_company_id: companyId
    });
    expect(detailsError).toBeNull();

    const { error: detailsErrorRepeat } = await superAuth.rpc('get_company_tier_details', {
      p_company_id: companyId
    });
    expect(detailsErrorRepeat).toBeNull();

    const events = await fetchEntitlementEvents(
      companyId,
      'entitlement.company_tier.override_expired',
      overrideRow.id
    );
    expect(events.length).toBe(1);
    expect(events[0]?.new_values?.new_effective_tier).toBe('starter');
  });

  it('rejects unauthorized override mutations', async () => {
    const { data, error } = await adminAuth.rpc('grant_company_tier_override', {
      p_company_id: companyId,
      p_override_tier: 'business',
      p_ends_at: null
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();

    const { data: baseData, error: baseError } = await adminAuth.rpc('set_company_base_tier', {
      p_company_id: companyId,
      p_new_base_tier: 'business'
    });
    expect(baseData).toBeNull();
    expect(baseError).not.toBeNull();
  });
});
