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

describe('RPC: seed_company_inventory', () => {
  let sourceCompanyId: string;
  let targetCompanyId: string;
  let superClient: SupabaseClient;
  let adminClientAuth: SupabaseClient;
  let superUserId: string;

  beforeAll(async () => {
    const sourceSlug = `seed-source-${uniqueSuffix}`;
    const targetSlug = `seed-target-${uniqueSuffix}`;

    const { data: sourceCompany, error: sourceError } = await adminClient
      .from('companies')
      .insert({
        name: `Seed Source ${uniqueSuffix}`,
        slug: sourceSlug,
        settings: { test: true },
        company_type: 'test'
      })
      .select()
      .single();
    if (sourceError || !sourceCompany) throw sourceError || new Error('Failed to create source company');
    sourceCompanyId = sourceCompany.id;

    const { data: targetCompany, error: targetError } = await adminClient
      .from('companies')
      .insert({
        name: `Seed Target ${uniqueSuffix}`,
        slug: targetSlug,
        settings: { test: true },
        company_type: 'test'
      })
      .select()
      .single();
    if (targetError || !targetCompany) throw targetError || new Error('Failed to create target company');
    targetCompanyId = targetCompany.id;

    superClient = await createAuthenticatedClient(TEST_USERS.SUPER, TEST_PASSWORD);
    adminClientAuth = await createAuthenticatedClient(TEST_USERS.ADMIN, TEST_PASSWORD);
    superUserId = await getAuthUserIdByEmail(TEST_USERS.SUPER);
    const { error: cleanupError } = await adminClient
      .from('company_members')
      .delete()
      .eq('user_id', superUserId);
    if (cleanupError) throw cleanupError;
    const { error: superMemberError } = await adminClient.from('company_members').insert({
      company_id: sourceCompanyId,
      user_id: superUserId,
      role: 'admin',
      is_super_user: true,
      assigned_admin_id: superUserId
    });
    if (superMemberError) throw superMemberError;

    const { error: sourceItemsError } = await adminClient.from('inventory_items').insert([
      {
        company_id: sourceCompanyId,
        name: 'Seed Widget A',
        description: 'Alpha item',
        quantity: 99,
        sku: 'SEED-A',
        unit_of_measure: 'box',
        is_active: true,
        reorder_point: 10,
        reorder_quantity: 50,
        unit_cost: 12.34,
        sale_price: 45.67,
        reorder_enabled: true,
        barcode: 'ABC-123',
        metadata: { supplier: 'hidden' },
        created_by: superUserId
      },
      {
        company_id: sourceCompanyId,
        name: 'Seed Widget B',
        description: 'No SKU item',
        quantity: 12,
        sku: null,
        unit_of_measure: 'each',
        is_active: true,
        reorder_point: 5,
        reorder_quantity: 5,
        unit_cost: 9.99,
        sale_price: 15.0,
        reorder_enabled: true,
        metadata: { supplier: 'hidden' },
        created_by: superUserId
      },
      {
        company_id: sourceCompanyId,
        name: 'Seed Widget C',
        description: 'Inactive item',
        quantity: 7,
        sku: 'SEED-C',
        unit_of_measure: 'pack',
        is_active: false,
        reorder_point: 3,
        reorder_quantity: 7,
        unit_cost: 5.55,
        sale_price: 8.88,
        reorder_enabled: true,
        metadata: { supplier: 'hidden' },
        created_by: superUserId
      }
    ]);
    if (sourceItemsError) throw sourceItemsError;

    const { error: targetItemsError } = await adminClient.from('inventory_items').insert([
      {
        company_id: targetCompanyId,
        name: 'Seed Widget A',
        description: 'Existing target',
        quantity: 1,
        sku: 'SEED-A',
        created_by: superUserId
      },
      {
        company_id: targetCompanyId,
        name: 'Seed Widget B',
        description: 'Existing target no sku',
        quantity: 1,
        sku: null,
        created_by: superUserId
      }
    ]);
    if (targetItemsError) throw targetItemsError;
  });

  it('rejects non-super_user callers', async () => {
    const { data, error } = await adminClientAuth.rpc('seed_company_inventory', {
      p_source_company_id: sourceCompanyId,
      p_target_company_id: targetCompanyId,
      p_mode: 'items_only',
      p_dedupe_key: 'sku'
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
  });

  it('seeds items, dedupes by sku, writes audit and seed run, and enforces allowlist', async () => {
    const { data, error } = await superClient.rpc('seed_company_inventory', {
      p_source_company_id: sourceCompanyId,
      p_target_company_id: targetCompanyId,
      p_mode: 'items_only',
      p_dedupe_key: 'sku'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(true);
    expect(data?.items_copied_count).toBe(1);

    const { data: targetItems, error: targetItemsFetchError } = await adminClient
      .from('inventory_items')
      .select('name,description,quantity,sku,unit_of_measure,is_active,reorder_point,reorder_quantity,unit_cost,sale_price,reorder_enabled,metadata,category_id,location_id,company_id,created_by')
      .eq('company_id', targetCompanyId)
      .order('name', { ascending: true });
    if (targetItemsFetchError) throw targetItemsFetchError;

    const seeded = (targetItems || []).find(item => item.sku === 'SEED-C');
    expect(seeded).toBeTruthy();
    expect(seeded?.company_id).toBe(targetCompanyId);
    expect(seeded?.created_by).toBe(superUserId);

    expect(seeded?.name).toBe('Seed Widget C');
    expect(seeded?.description).toBe('Inactive item');
    expect(seeded?.sku).toBe('SEED-C');
    expect(seeded?.unit_of_measure).toBe('pack');
    expect(seeded?.is_active).toBe(false);
    expect(seeded?.reorder_point).toBe(3);
    expect(seeded?.reorder_quantity).toBe(7);

    expect(seeded?.quantity).toBe(0);
    expect(seeded?.unit_cost).toBeNull();
    expect(seeded?.sale_price).toBeNull();
    expect(seeded?.reorder_enabled).toBe(false);
    expect(seeded?.metadata).toEqual({});
    expect(seeded?.category_id).toBeNull();
    expect(seeded?.location_id).toBeNull();

    const dupSkuCount = (targetItems || []).filter(item => item.sku === 'SEED-A').length;
    expect(dupSkuCount).toBe(1);
    const dupNameCount = (targetItems || []).filter(item => item.name === 'Seed Widget B').length;
    expect(dupNameCount).toBe(1);

    const { data: seedRun, error: seedRunError } = await adminClient
      .from('inventory_seed_runs')
      .select('id,source_company_id,target_company_id,mode,dedupe_key,items_copied_count,created_by')
      .eq('target_company_id', targetCompanyId)
      .single();
    if (seedRunError) throw seedRunError;
    expect(seedRun?.source_company_id).toBe(sourceCompanyId);
    expect(seedRun?.target_company_id).toBe(targetCompanyId);
    expect(seedRun?.mode).toBe('items_only');
    expect(seedRun?.dedupe_key).toBe('sku');
    expect(seedRun?.items_copied_count).toBe(1);
    expect(seedRun?.created_by).toBe(superUserId);

    const { data: auditRows, error: auditError } = await adminClient
      .from('audit_log')
      .select('id,new_values')
      .eq('company_id', targetCompanyId)
      .eq('table_name', 'inventory_seed_events')
      .order('created_at', { ascending: false });
    if (auditError) throw auditError;
    const auditRow = (auditRows || []).find(row => row.new_values?.event_name === 'inventory_seeded');
    expect(auditRow).toBeTruthy();
    expect(auditRow?.new_values?.actor_user_id).toBe(superUserId);
    expect(auditRow?.new_values?.source_company_id).toBe(sourceCompanyId);
    expect(auditRow?.new_values?.target_company_id).toBe(targetCompanyId);
    expect(auditRow?.new_values?.mode).toBe('items_only');
    expect(auditRow?.new_values?.dedupe_key).toBe('sku');
    expect(auditRow?.new_values?.items_copied_count).toBe(1);
  });

  it('blocks a second seed run for the same target company', async () => {
    const { data, error } = await superClient.rpc('seed_company_inventory', {
      p_source_company_id: sourceCompanyId,
      p_target_company_id: targetCompanyId,
      p_mode: 'items_only',
      p_dedupe_key: 'sku'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
  });
});
