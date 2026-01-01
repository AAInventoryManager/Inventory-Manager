import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  TEST_PASSWORD,
  TEST_USERS
} from '../../setup/test-utils';

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

async function createCompany(name: string, type: 'production' | 'test'): Promise<string> {
  const slug = `${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${uniqueSuffix}`;
  const { data, error } = await adminClient
    .from('companies')
    .insert({ name, slug, settings: { test: true }, company_type: type })
    .select('id')
    .single();
  if (error || !data) throw error || new Error('Failed to create company');
  return data.id;
}

async function createInventoryItem(companyId: string, name: string, sku: string | null, userId: string) {
  const { error } = await adminClient.from('inventory_items').insert({
    company_id: companyId,
    name,
    description: `${name} desc`,
    quantity: 1,
    sku,
    created_by: userId
  });
  if (error) throw error;
}

describe.sequential('Company environment guardrails', () => {
  let superAuth: SupabaseClient;
  let superUserId: string;
  let adminUserId: string;
  let memberUserId: string;

  beforeAll(async () => {
    superAuth = await createAuthenticatedClient(TEST_USERS.SUPER, TEST_PASSWORD);
    superUserId = await getAuthUserIdByEmail(TEST_USERS.SUPER);
    adminUserId = await getAuthUserIdByEmail(TEST_USERS.ADMIN);
    memberUserId = await getAuthUserIdByEmail(TEST_USERS.MEMBER);
    const membershipCompanyId = await createCompany(`Super Membership ${uniqueSuffix}`, 'test');
    const { error: cleanupError } = await adminClient
      .from('company_members')
      .delete()
      .eq('user_id', superUserId);
    if (cleanupError) throw cleanupError;
    const { error: superMemberError } = await adminClient.from('company_members').insert({
      company_id: membershipCompanyId,
      user_id: superUserId,
      role: 'admin',
      is_super_user: true,
      assigned_admin_id: superUserId
    });
    if (superMemberError) throw superMemberError;
  });

  it('blocks inventory seeding for production targets', async () => {
    const sourceCompanyId = await createCompany(`Seed Source ${uniqueSuffix}`, 'test');
    const targetCompanyId = await createCompany(`Seed Target ${uniqueSuffix}`, 'production');

    await createInventoryItem(sourceCompanyId, 'Seed Prod Block', 'SEED-PROD', superUserId);

    const { data, error } = await superAuth.rpc('seed_company_inventory', {
      p_source_company_id: sourceCompanyId,
      p_target_company_id: targetCompanyId,
      p_mode: 'items_only',
      p_dedupe_key: 'sku'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
    expect(String(data?.error || '')).toMatch(/test environment/i);
  });

  it('allows seed reset only for test environments', async () => {
    const testCompanyId = await createCompany(`Seed Reset Test ${uniqueSuffix}`, 'test');
    const sourceCompanyId = await createCompany(`Seed Reset Source ${uniqueSuffix}`, 'test');

    const { error: seedRunError } = await adminClient.from('inventory_seed_runs').insert({
      source_company_id: sourceCompanyId,
      target_company_id: testCompanyId,
      mode: 'items_only',
      dedupe_key: 'sku',
      items_copied_count: 0,
      created_by: superUserId,
      created_at: new Date().toISOString()
    });
    if (seedRunError) throw seedRunError;

    const { data: okData, error: okError } = await superAuth.rpc('reset_inventory_seed_run', {
      p_target_company_id: testCompanyId
    });
    expect(okError).toBeNull();
    expect(okData?.success).toBe(true);
    expect(okData?.deleted).toBeGreaterThan(0);

    const prodCompanyId = await createCompany(`Seed Reset Prod ${uniqueSuffix}`, 'production');
    const { data: prodData, error: prodError } = await superAuth.rpc('reset_inventory_seed_run', {
      p_target_company_id: prodCompanyId
    });
    expect(prodError).toBeNull();
    expect(prodData?.success).toBe(false);
  });

  it('deletes inventory only for test environments', async () => {
    const testCompanyId = await createCompany(`Delete Inv Test ${uniqueSuffix}`, 'test');
    await createInventoryItem(testCompanyId, 'Delete Inv A', 'DEL-A', superUserId);
    await createInventoryItem(testCompanyId, 'Delete Inv B', 'DEL-B', superUserId);

    const { data: okData, error: okError } = await superAuth.rpc('delete_company_inventory', {
      p_company_id: testCompanyId
    });
    expect(okError).toBeNull();
    expect(okData?.success).toBe(true);
    expect(okData?.deleted_count).toBe(2);

    const { data: deletedItems, error: deletedError } = await adminClient
      .from('inventory_items')
      .select('deleted_at')
      .eq('company_id', testCompanyId);
    if (deletedError) throw deletedError;
    const deletedCount = (deletedItems || []).filter(row => row.deleted_at !== null).length;
    expect(deletedCount).toBe(2);

    const prodCompanyId = await createCompany(`Delete Inv Prod ${uniqueSuffix}`, 'production');
    await createInventoryItem(prodCompanyId, 'Delete Inv Prod', 'DEL-P', superUserId);

    const { data: prodData, error: prodError } = await superAuth.rpc('delete_company_inventory', {
      p_company_id: prodCompanyId
    });
    expect(prodError).toBeNull();
    expect(prodData?.success).toBe(false);
  });

  it('deletes users only for test environments', async () => {
    const testCompanyId = await createCompany(`Delete Users Test ${uniqueSuffix}`, 'test');

    const { error: memberError } = await adminClient.from('company_members').insert([
      {
        company_id: testCompanyId,
        user_id: adminUserId,
        role: 'admin',
        assigned_admin_id: adminUserId,
        invited_by: adminUserId,
        is_super_user: false
      },
      {
        company_id: testCompanyId,
        user_id: memberUserId,
        role: 'member',
        assigned_admin_id: adminUserId,
        invited_by: adminUserId,
        is_super_user: false
      }
    ]);
    if (memberError) throw memberError;

    const { data: okData, error: okError } = await superAuth.rpc('delete_company_users', {
      p_company_id: testCompanyId
    });
    expect(okError).toBeNull();
    expect(okData?.success).toBe(true);
    expect(okData?.deleted_count).toBe(2);

    const { data: remaining, error: remainingError } = await adminClient
      .from('company_members')
      .select('user_id')
      .eq('company_id', testCompanyId)
      .eq('is_super_user', false);
    if (remainingError) throw remainingError;
    expect(remaining?.length || 0).toBe(0);

    const prodCompanyId = await createCompany(`Delete Users Prod ${uniqueSuffix}`, 'production');
    const { error: prodMemberError } = await adminClient.from('company_members').insert({
      company_id: prodCompanyId,
      user_id: memberUserId,
      role: 'member',
      assigned_admin_id: adminUserId,
      invited_by: adminUserId,
      is_super_user: false
    });
    if (prodMemberError) throw prodMemberError;

    const { data: prodData, error: prodError } = await superAuth.rpc('delete_company_users', {
      p_company_id: prodCompanyId
    });
    expect(prodError).toBeNull();
    expect(prodData?.success).toBe(false);
  });

  it('deletes company records only for test environments', async () => {
    const testCompanyId = await createCompany(`Delete Company Test ${uniqueSuffix}`, 'test');

    const { data: okData, error: okError } = await superAuth.rpc('delete_company_record', {
      p_company_id: testCompanyId
    });
    expect(okError).toBeNull();
    expect(okData?.success).toBe(true);

    const { data: goneCompany, error: goneError } = await adminClient
      .from('companies')
      .select('id')
      .eq('id', testCompanyId)
      .maybeSingle();
    if (goneError) throw goneError;
    expect(goneCompany).toBeNull();

    const prodCompanyId = await createCompany(`Delete Company Prod ${uniqueSuffix}`, 'production');
    const { data: prodData, error: prodError } = await superAuth.rpc('delete_company_record', {
      p_company_id: prodCompanyId
    });
    expect(prodError).toBeNull();
    expect(prodData?.success).toBe(false);
  });
});
