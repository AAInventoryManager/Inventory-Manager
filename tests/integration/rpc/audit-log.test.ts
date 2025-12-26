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

async function getLatestAuditId(recordId: string) {
  const { data, error } = await adminClient
    .from('audit_log')
    .select('id')
    .eq('table_name', 'inventory_items')
    .eq('record_id', recordId)
    .order('created_at', { ascending: false })
    .limit(1)
    .single();
  if (error || !data) throw error || new Error('Audit entry not found');
  return data.id as string;
}

describe('RPC: audit log and undo actions', () => {
  let adminClientAuth: SupabaseClient;
  let memberClientAuth: SupabaseClient;
  let mainCompanyId: string;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    memberClientAuth = await getClient('MEMBER');
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
    await setCompanyTier(mainCompanyId, 'enterprise');
  });

  it('blocks audit log when tier is below enterprise', async () => {
    await setCompanyTier(mainCompanyId, 'starter');

    const { error } = await adminClientAuth.rpc('get_audit_log', {
      p_company_id: mainCompanyId,
      p_limit: 10,
      p_offset: 0
    });

    expect(error).not.toBeNull();
    expect(error?.message || '').toMatch(/plan/i);

    await setCompanyTier(mainCompanyId, 'enterprise');
  });

  it('requires audit_log:view permission', async () => {
    const { error } = await memberClientAuth.rpc('get_audit_log', {
      p_company_id: mainCompanyId,
      p_limit: 10,
      p_offset: 0
    });

    expect(error).not.toBeNull();
    expect(error?.message || '').toMatch(/permission/i);
  });

  it('returns audit entries for admin on enterprise tier', async () => {
    const { data: item, error } = await adminClientAuth
      .from('inventory_items')
      .select('id, quantity')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single();

    expect(error).toBeNull();
    if (!item?.id) throw new Error('No inventory item available');

    const originalQty = typeof item.quantity === 'number' ? item.quantity : 0;
    const updatedQty = originalQty + 1;

    const { error: updateError } = await adminClientAuth
      .from('inventory_items')
      .update({ quantity: updatedQty })
      .eq('id', item.id);

    expect(updateError).toBeNull();

    const { data, error: auditError } = await adminClientAuth.rpc('get_audit_log', {
      p_company_id: mainCompanyId,
      p_limit: 50,
      p_offset: 0,
      p_table_name: 'inventory_items',
      p_action: 'UPDATE'
    });

    expect(auditError).toBeNull();
    const rows = Array.isArray(data) ? data : [];
    expect(rows.some(row => String(row.record_id) === String(item.id))).toBe(true);
  });

  it('enforces permissions and restores updates via undo_action', async () => {
    const { data: item, error } = await adminClientAuth
      .from('inventory_items')
      .select('id, quantity')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single();

    expect(error).toBeNull();
    if (!item?.id) throw new Error('No inventory item available');

    const originalQty = typeof item.quantity === 'number' ? item.quantity : 0;
    const updatedQty = originalQty + 2;

    const { error: updateError } = await adminClientAuth
      .from('inventory_items')
      .update({ quantity: updatedQty })
      .eq('id', item.id);

    expect(updateError).toBeNull();

    const auditId = await getLatestAuditId(item.id);

    const { data: memberUndo } = await memberClientAuth.rpc('undo_action', {
      p_audit_id: auditId
    });
    expect(memberUndo?.success).toBe(false);

    const { data: adminUndo, error: adminUndoError } = await adminClientAuth.rpc('undo_action', {
      p_audit_id: auditId
    });

    expect(adminUndoError).toBeNull();
    expect(adminUndo?.success).toBe(true);

    const { data: restored, error: restoredError } = await adminClientAuth
      .from('inventory_items')
      .select('quantity')
      .eq('id', item.id)
      .single();

    expect(restoredError).toBeNull();
    expect(restored?.quantity).toBe(originalQty);
  });
});
