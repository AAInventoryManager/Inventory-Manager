import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { getClient, getCompanyId, adminClient, TEST_COMPANIES, TEST_USERS } from '../../setup/test-utils';

describe('RLS: inventory_items', () => {
  let superClient: SupabaseClient;
  let adminClientAuth: SupabaseClient;
  let memberClient: SupabaseClient;
  let viewerClient: SupabaseClient;
  let otherAdminClient: SupabaseClient;
  let mainCompanyId: string;
  let otherCompanyId: string;

  beforeAll(async () => {
    superClient = await getClient('SUPER');
    adminClientAuth = await getClient('ADMIN');
    memberClient = await getClient('MEMBER');
    viewerClient = await getClient('VIEWER');
    otherAdminClient = await getClient('OTHER_ADMIN');

    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER.slug);
  });

  it('super user can see items across companies', async () => {
    const { data, error } = await superClient
      .from('inventory_items')
      .select('company_id');

    expect(error).toBeNull();
    const companyIds = new Set((data || []).map(row => row.company_id));
    expect(companyIds.has(mainCompanyId)).toBe(true);
    expect(companyIds.has(otherCompanyId)).toBe(true);
  });

  it('admin cannot read other company items', async () => {
    const { data, error } = await adminClientAuth
      .from('inventory_items')
      .select('id')
      .eq('company_id', otherCompanyId);

    expect(error).toBeNull();
    expect(data || []).toHaveLength(0);
  });

  it('viewer cannot create items', async () => {
    const { error } = await viewerClient
      .from('inventory_items')
      .insert({
        company_id: mainCompanyId,
        name: `Viewer Item ${Date.now()}`,
        quantity: 1,
        sku: `VIEW-${Date.now()}`
      });

    expect(error).not.toBeNull();
  });

  it('member can create items in own company', async () => {
    const name = `Member Item ${Date.now()}`;
    const sku = `MEM-${Date.now()}`;
    const { data, error } = await memberClient
      .from('inventory_items')
      .insert({
        company_id: mainCompanyId,
        name,
        quantity: 2,
        sku
      })
      .select()
      .single();

    expect(error).toBeNull();
    expect(data?.name).toBe(name);

    if (data?.id) {
      await adminClient.from('inventory_items').delete().eq('id', data.id);
    }
  });

  it('admin cannot insert into another company', async () => {
    const { error } = await adminClientAuth
      .from('inventory_items')
      .insert({
        company_id: otherCompanyId,
        name: `Cross Item ${Date.now()}`,
        quantity: 1,
        sku: `X-${Date.now()}`
      });

    expect(error).not.toBeNull();
  });

  it('soft-deleted items are hidden for non-admins', async () => {
    const { data: item, error: fetchError } = await adminClientAuth
      .from('inventory_items')
      .select('id')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single();

    expect(fetchError).toBeNull();
    if (!item?.id) throw new Error('No inventory item found for soft delete test');

    const { error: deleteError } = await adminClientAuth.rpc('soft_delete_item', { p_item_id: item.id });
    expect(deleteError).toBeNull();

    const { data: memberView } = await memberClient
      .from('inventory_items')
      .select('id')
      .eq('id', item.id);
    expect(memberView || []).toHaveLength(0);

    const { data: adminView } = await adminClientAuth
      .from('inventory_items')
      .select('id')
      .eq('id', item.id)
      .not('deleted_at', 'is', null);
    expect(adminView || []).toHaveLength(1);

    await adminClientAuth.rpc('restore_item', { p_item_id: item.id });
  });
});
