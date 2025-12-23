import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { getClient, getCompanyId, TEST_COMPANIES } from '../../setup/test-utils';

describe('RPC: soft delete inventory items', () => {
  let adminClientAuth: SupabaseClient;
  let mainCompanyId: string;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
  });

  it('soft deletes and restores an item', async () => {
    const { data: item, error } = await adminClientAuth
      .from('inventory_items')
      .select('id')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single();

    expect(error).toBeNull();
    if (!item?.id) throw new Error('No inventory item available');

    const { error: deleteError } = await adminClientAuth.rpc('soft_delete_item', { p_item_id: item.id });
    expect(deleteError).toBeNull();

    const { data: deleted, error: deletedError } = await adminClientAuth
      .from('inventory_items')
      .select('id, deleted_at')
      .eq('id', item.id)
      .not('deleted_at', 'is', null)
      .single();

    expect(deletedError).toBeNull();
    expect(deleted?.deleted_at).not.toBeNull();

    const { error: restoreError } = await adminClientAuth.rpc('restore_item', { p_item_id: item.id });
    expect(restoreError).toBeNull();

    const { data: restored, error: restoredError } = await adminClientAuth
      .from('inventory_items')
      .select('deleted_at')
      .eq('id', item.id)
      .single();

    expect(restoredError).toBeNull();
    expect(restored?.deleted_at).toBeNull();
  });
});
