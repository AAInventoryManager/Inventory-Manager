import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { adminClient, getClient, getCompanyId, TEST_COMPANIES } from '../../setup/test-utils';

type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

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

describe('RLS: audit_log', () => {
  let adminClientAuth: SupabaseClient;
  let memberClientAuth: SupabaseClient;
  let otherAdminClient: SupabaseClient;
  let mainCompanyId: string;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    memberClientAuth = await getClient('MEMBER');
    otherAdminClient = await getClient('OTHER_ADMIN');
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
    await setCompanyTier(mainCompanyId, 'enterprise');

    const { data: item, error } = await adminClientAuth
      .from('inventory_items')
      .select('id, quantity')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single();

    expect(error).toBeNull();
    if (!item?.id) throw new Error('No inventory item available');

    const originalQty = typeof item.quantity === 'number' ? item.quantity : 0;
    const updatedQty = originalQty + 3;

    const { error: updateError } = await adminClientAuth
      .from('inventory_items')
      .update({ quantity: updatedQty })
      .eq('id', item.id);

    expect(updateError).toBeNull();
  });

  it('admin can view audit log for own company when enterprise tier', async () => {
    const { data, error } = await adminClientAuth
      .from('audit_log')
      .select('id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect((data || []).length).toBeGreaterThan(0);
  });

  it('member cannot view audit log even with enterprise tier', async () => {
    const { data, error } = await memberClientAuth
      .from('audit_log')
      .select('id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect(data || []).toHaveLength(0);
  });

  it('other company admin cannot view main company audit log', async () => {
    const { data, error } = await otherAdminClient
      .from('audit_log')
      .select('id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect(data || []).toHaveLength(0);
  });

  it('tier below enterprise blocks audit log select', async () => {
    await setCompanyTier(mainCompanyId, 'starter');

    const { data, error } = await adminClientAuth
      .from('audit_log')
      .select('id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect(data || []).toHaveLength(0);

    await setCompanyTier(mainCompanyId, 'enterprise');
  });
});
