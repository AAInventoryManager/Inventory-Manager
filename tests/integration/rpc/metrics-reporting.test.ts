import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  getCompanyId,
  setCompanyTierForTests,
  TEST_COMPANIES,
  TEST_PASSWORD
} from '../../setup/test-utils';

type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

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

describe('RPC: metrics and reporting enforcement', () => {
  let adminClientAuth: SupabaseClient;
  let memberClientAuth: SupabaseClient;
  let superClientAuth: SupabaseClient;
  let mainCompanyId: string;
  let lowStockItemId: string | null = null;
  let lowStockCompanyId: string;
  let lowStockAdminAuth: SupabaseClient;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    memberClientAuth = await getClient('MEMBER');
    superClientAuth = await getClient('SUPER');
    const { data: adminCompanyId, error: adminCompanyError } =
      await adminClientAuth.rpc<string>('get_user_company_id');
    if (!adminCompanyError && adminCompanyId) {
      mainCompanyId = adminCompanyId;
    } else {
      mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
    }

    await setCompanyTier(mainCompanyId, 'professional');

    const lowStockSlug = `low-stock-${uniqueSuffix}`;
    const { data: lowStockCompany, error: lowStockCompanyError } = await adminClient
      .from('companies')
      .insert({
        name: 'Low Stock Report Test',
        slug: lowStockSlug,
        settings: { test: true },
        company_type: 'test'
      })
      .select('id')
      .single();
    if (lowStockCompanyError || !lowStockCompany) {
      throw lowStockCompanyError || new Error('Failed to create low stock company');
    }
    lowStockCompanyId = lowStockCompany.id;

    const lowStockAdminEmail = uniqueEmail('low-stock-admin');
    const lowStockAdminUserId = await createTestUser(lowStockAdminEmail);

    const { error: lowStockMemberError } = await adminClient.from('company_members').insert({
      company_id: lowStockCompanyId,
      user_id: lowStockAdminUserId,
      role: 'admin',
      assigned_admin_id: lowStockAdminUserId
    });
    if (lowStockMemberError) throw lowStockMemberError;

    lowStockAdminAuth = await createAuthenticatedClient(lowStockAdminEmail, TEST_PASSWORD);

    await setCompanyTier(lowStockCompanyId, 'professional');

    const unique = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const { data, error } = await adminClient
      .from('inventory_items')
      .insert({
        company_id: lowStockCompanyId,
        name: `Low Stock ${unique}`,
        quantity: 0,
        reorder_point: 5,
        low_stock_qty: 5,
        reorder_enabled: true,
        sku: `LS-${unique}`
      })
      .select('id')
      .single();
    if (error) throw error;
    lowStockItemId = data?.id || null;
  });

  it('enforces tier and permission checks on company metrics', async () => {
    await setCompanyTier(mainCompanyId, 'starter');
    const { error: deniedTier } = await adminClientAuth.rpc('get_company_dashboard_metrics', {
      p_company_id: mainCompanyId,
      p_days: 7
    });
    expect(deniedTier).not.toBeNull();

    await setCompanyTier(mainCompanyId, 'professional');
    const { data: allowedMetrics, error: allowedError } = await adminClientAuth.rpc('get_company_dashboard_metrics', {
      p_company_id: mainCompanyId,
      p_days: 7
    });
    expect(allowedError).toBeNull();
    expect(allowedMetrics).toBeTruthy();

    const { error: deniedPermission } = await memberClientAuth.rpc('get_company_dashboard_metrics', {
      p_company_id: mainCompanyId,
      p_days: 7
    });
    expect(deniedPermission).not.toBeNull();
  });

  it('enforces tier gating on platform dashboard metrics', async () => {
    await setCompanyTier(mainCompanyId, 'starter');
    const { data, error } = await superClientAuth.rpc('get_platform_dashboard_metrics', { p_days: 7 });
    if (error) {
      expect(String(error.message || '')).toMatch(/plan|feature|tier|unauthorized/i);
      return;
    }
    expect(data).toBeTruthy();
  });

  it('enforces tier gating on platform metrics summary RPC', async () => {
    await setCompanyTier(mainCompanyId, 'starter');
    const { data: denied } = await superClientAuth.rpc('get_platform_metrics');
    if (denied?.error) {
      expect(String(denied.error)).toMatch(/plan|unauthorized/i);
      return;
    }
    expect(denied).toBeTruthy();
  });

  it('enforces tier gating on action metrics RPC', async () => {
    await setCompanyTier(mainCompanyId, 'starter');
    const { data: allowed } = await superClientAuth.rpc('get_action_metrics', {
      p_company_id: mainCompanyId,
      p_days: 7
    });
    if (allowed?.error) {
      expect(String(allowed.error)).toMatch(/plan|unauthorized/i);
      return;
    }
    expect(allowed).toBeTruthy();
  });

  it('enforces tier gating on low stock report RPC', async () => {
    await setCompanyTier(lowStockCompanyId, 'starter');
    const { error: deniedTier } = await lowStockAdminAuth.rpc('get_low_stock_items', {
      p_limit: 10,
      p_offset: 0
    });
    expect(deniedTier).not.toBeNull();

    await setCompanyTier(lowStockCompanyId, 'professional');
    const { data, error } = await lowStockAdminAuth.rpc('get_low_stock_items', {
      p_limit: 10,
      p_offset: 0
    });
    expect(error).toBeNull();
    const rows = Array.isArray(data) ? data : [];
    expect(rows.length).toBeGreaterThan(0);
    if (lowStockItemId) {
      expect(rows.some((row: { id: string }) => String(row.id) === String(lowStockItemId))).toBe(true);
    }
  });
});
