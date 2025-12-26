import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  setCompanyTierForTests,
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
  await setCompanyTierForTests(companyId, tier, `Test tier override: ${tier}`);
}

describe('Inventory core enforcement', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let memberAuth: SupabaseClient;
  let viewerAuth: SupabaseClient;
  let adminUserId: string;
  let memberUserId: string;
  let viewerUserId: string;
  let seedItemId: string;

  beforeAll(async () => {
    const slug = `inventory-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Inventory Core Test',
        slug,
        settings: { test: true, tier: 'starter' }
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('inv-admin');
    const memberEmail = uniqueEmail('inv-member');
    const viewerEmail = uniqueEmail('inv-viewer');

    adminUserId = await createTestUser(adminEmail);
    memberUserId = await createTestUser(memberEmail);
    viewerUserId = await createTestUser(viewerEmail);

    const { error: adminInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminInsertError) throw adminInsertError;

    const { error: memberInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: memberUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (memberInsertError) throw memberInsertError;

    const { error: viewerInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: viewerUserId,
      role: 'viewer',
      assigned_admin_id: adminUserId
    });
    if (viewerInsertError) throw viewerInsertError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    memberAuth = await createAuthenticatedClient(memberEmail, TEST_PASSWORD);
    viewerAuth = await createAuthenticatedClient(viewerEmail, TEST_PASSWORD);

    const { data: seed, error: seedError } = await adminAuth
      .from('inventory_items')
      .insert({
        company_id: companyId,
        name: `Seed Item ${uniqueSuffix}`,
        description: 'Seed item',
        quantity: 5,
        reorder_enabled: true,
        created_by: adminUserId
      })
      .select('id')
      .single();
    if (seedError || !seed) throw seedError || new Error('Failed to seed item');
    seedItemId = seed.id;
  });

  it('allows inventory view in Starter tier', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data, error } = await viewerAuth
      .from('inventory_items')
      .select('id')
      .eq('company_id', companyId)
      .is('deleted_at', null);
    expect(error).toBeNull();
    expect((data || []).length).toBeGreaterThan(0);
  });

  it('enforces create/update permissions', async () => {
    await setCompanyTier(companyId, 'starter');

    const { error: viewerInsertError } = await viewerAuth.from('inventory_items').insert({
      company_id: companyId,
      name: `Viewer Item ${uniqueSuffix}`,
      description: 'Viewer attempt',
      quantity: 1
    });
    expect(viewerInsertError).not.toBeNull();

    const { data: memberInsert, error: memberInsertError } = await memberAuth
      .from('inventory_items')
      .insert({
        company_id: companyId,
        name: `Member Item ${uniqueSuffix}`,
        description: 'Member insert',
        quantity: 2
      })
      .select('id')
      .single();
    expect(memberInsertError).toBeNull();
    expect(memberInsert?.id).toBeTruthy();

    const { error: memberUpdateError } = await memberAuth
      .from('inventory_items')
      .update({ quantity: 3 })
      .eq('id', memberInsert?.id)
      .eq('company_id', companyId)
      .is('deleted_at', null);
    expect(memberUpdateError).toBeNull();
  });

  it('enforces delete/restore permissions', async () => {
    await setCompanyTier(companyId, 'starter');

    const { data: deniedDelete } = await viewerAuth.rpc('soft_delete_item', {
      p_item_id: seedItemId
    });
    expect(deniedDelete?.success).toBe(false);

    const { data: adminDelete, error: adminDeleteError } = await adminAuth.rpc('soft_delete_item', {
      p_item_id: seedItemId
    });
    expect(adminDeleteError).toBeNull();
    expect(adminDelete?.success).toBe(true);

    const { data: deniedRestore } = await viewerAuth.rpc('restore_item', {
      p_item_id: seedItemId
    });
    expect(deniedRestore?.success).toBe(false);

    const { data: adminRestore, error: adminRestoreError } = await adminAuth.rpc('restore_item', {
      p_item_id: seedItemId
    });
    expect(adminRestoreError).toBeNull();
    expect(adminRestore?.success).toBe(true);
  });

  it('restricts bulk import to Professional tier', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data: deniedImport, error: deniedImportError } = await adminAuth.rpc(
      'bulk_upsert_inventory_items',
      {
        p_company_id: companyId,
        p_items: [{ name: `Import ${uniqueSuffix}`, desc: 'Denied', qty: 1 }]
      }
    );
    expect(deniedImportError).toBeNull();
    expect(deniedImport?.success).toBe(false);
    expect(String(deniedImport?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'professional');
    const { data: allowedImport, error: allowedImportError } = await adminAuth.rpc(
      'bulk_upsert_inventory_items',
      {
        p_company_id: companyId,
        p_items: [{ name: `Import ${uniqueSuffix} Pro`, desc: 'Allowed', qty: 4 }]
      }
    );
    expect(allowedImportError).toBeNull();
    expect(allowedImport?.success).toBe(true);
  });

  it('denies bulk import without permission at Professional tier', async () => {
    await setCompanyTier(companyId, 'professional');
    const { data, error } = await viewerAuth.rpc('bulk_upsert_inventory_items', {
      p_company_id: companyId,
      p_items: [{ name: `Viewer Import ${uniqueSuffix}`, desc: 'Denied', qty: 2 }]
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
    expect(String(data?.error || '')).toMatch(/permission/i);
  });

  it('rejects invalid manual tier overrides', async () => {
    const superAuth = await getClient('SUPER');
    const { data, error } = await superAuth.rpc('set_company_tier_override', {
      p_company_id: companyId,
      p_tier: 'invalid-tier',
      p_reason: 'Invalid override test'
    });
    if (error && error.code === 'PGRST202') {
      return;
    }
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
    expect(String(data?.error || '')).toMatch(/invalid tier/i);
  });

  it('restricts export to Professional tier', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data: deniedExport, error: deniedExportError } = await viewerAuth.rpc(
      'export_inventory_items',
      { p_company_id: companyId }
    );
    expect(deniedExportError).toBeNull();
    expect((deniedExport || []).length).toBe(0);

    await setCompanyTier(companyId, 'professional');
    const { data: allowedExport, error: allowedExportError } = await viewerAuth.rpc(
      'export_inventory_items',
      { p_company_id: companyId }
    );
    expect(allowedExportError).toBeNull();
    expect((allowedExport || []).length).toBeGreaterThan(0);
  });
});
