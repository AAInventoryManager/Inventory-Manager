import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  TEST_PASSWORD
} from '../../setup/test-utils';

type Tier = 'starter' | 'professional' | 'business' | 'enterprise' | string;

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

function uniqueEmail(prefix: string) {
  return `${prefix}+${uniqueSuffix}@test.local`;
}

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

async function setCompanyTier(companyId: string, tier: Tier) {
  const superAuth = await getClient('SUPER');
  const overrideTier = tier === 'starter' ? null : tier;
  await adminClient.from('billing_subscriptions').delete().eq('company_id', companyId);
  const { data, error } = await superAuth.rpc('set_company_tier_override', {
    p_company_id: companyId,
    p_tier: overrideTier,
    p_reason: `Test tier override: ${tier}`
  });
  if (error) throw error;
  if (data && data.success === false) throw new Error(data.error || 'Tier override failed');
}

describe('Snapshots entitlement enforcement', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let viewerAuth: SupabaseClient;
  let adminUserId: string;

  beforeAll(async () => {
    const slug = `snapshots-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Snapshots Test',
        slug,
        settings: { test: true, tier: 'business' }
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('snapshots-admin');
    const viewerEmail = uniqueEmail('snapshots-viewer');

    adminUserId = await createTestUser(adminEmail);
    const viewerUserId = await createTestUser(viewerEmail);

    const { error: adminInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminInsertError) throw adminInsertError;

    const { error: viewerInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: viewerUserId,
      role: 'viewer',
      assigned_admin_id: adminUserId
    });
    if (viewerInsertError) throw viewerInsertError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    viewerAuth = await createAuthenticatedClient(viewerEmail, TEST_PASSWORD);

    const { error: snapshotError } = await adminClient
      .from('inventory_snapshots')
      .insert({
        company_id: companyId,
        name: `Snapshot ${uniqueSuffix}`,
        description: 'Snapshot seed',
        snapshot_type: 'manual',
        items_data: [],
        items_count: 0,
        total_quantity: 0,
        created_by: adminUserId
      });
    if (snapshotError) throw snapshotError;
  });

  it('denies snapshots when tier is Starter', async () => {
    await setCompanyTier(companyId, 'starter');
    const { error } = await adminAuth.rpc('get_snapshots', { p_company_id: companyId });
    expect(error).not.toBeNull();
    expect(String(error?.message || '')).toMatch(/plan/i);
  });

  it('denies snapshots without permission', async () => {
    await setCompanyTier(companyId, 'business');
    const { error } = await viewerAuth.rpc('get_snapshots', { p_company_id: companyId });
    expect(error).not.toBeNull();
    expect(String(error?.message || '')).toMatch(/permission/i);
  });

  it('allows snapshot access via RLS at Business tier', async () => {
    await setCompanyTier(companyId, 'business');
    const { data, error } = await adminAuth
      .from('inventory_snapshots')
      .select('id')
      .eq('company_id', companyId);
    expect(error).toBeNull();
    const rows = Array.isArray(data) ? data : [];
    expect(rows.length).toBeGreaterThan(0);
  });
});
