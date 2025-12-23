import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { getClient, getCompanyId, adminClient, TEST_COMPANIES } from '../../setup/test-utils';

describe('Security: company_id immutability', () => {
  let adminClientAuth: SupabaseClient;
  let mainCompanyId: string;
  let otherCompanyId: string;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER.slug);
  });

  it('prevents changing company_id on inventory_items', async () => {
    const name = `Immutable Item ${Date.now()}`;
    const sku = `IMM-${Date.now()}`;

    const { data: item, error } = await adminClientAuth
      .from('inventory_items')
      .insert({
        company_id: mainCompanyId,
        name,
        quantity: 1,
        sku
      })
      .select()
      .single();

    expect(error).toBeNull();
    if (!item?.id) throw new Error('Failed to create inventory item');

    const { error: updateError } = await adminClientAuth
      .from('inventory_items')
      .update({ company_id: otherCompanyId })
      .eq('id', item.id);

    expect(updateError).not.toBeNull();

    await adminClient.from('inventory_items').delete().eq('id', item.id);
  });
});
