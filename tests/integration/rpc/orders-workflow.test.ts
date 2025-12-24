import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  SUPABASE_ANON_KEY,
  SUPABASE_URL,
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
  const { data, error } = await adminClient
    .from('companies')
    .select('settings')
    .eq('id', companyId)
    .single();
  if (error) throw error;
  const settings = data?.settings && typeof data.settings === 'object' ? data.settings : {};
  const { error: updateError } = await adminClient
    .from('companies')
    .update({ settings: { ...settings, tier } })
    .eq('id', companyId);
  if (updateError) throw updateError;
}

describe('Orders: tier and permission enforcement', () => {
  let companyId: string;
  let orderId: string;
  let adminAuth: SupabaseClient;
  let memberAuth: SupabaseClient;
  let viewerAuth: SupabaseClient;
  let adminUserId: string;
  let memberUserId: string;
  let viewerUserId: string;

  beforeAll(async () => {
    const slug = `orders-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Orders Enforcement Test',
        slug,
        settings: { test: true, tier: 'business' }
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('orders-admin');
    const memberEmail = uniqueEmail('orders-member');
    const viewerEmail = uniqueEmail('orders-viewer');

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

    const { data: orderRow, error: orderError } = await adminAuth
      .from('orders')
      .insert({
        company_id: companyId,
        created_by: adminUserId,
        to_email: 'orders@test.local',
        reply_to_email: adminEmail,
        subject: 'Test Order',
        contact_name: 'Test',
        notes: 'Seed order',
        line_items: [{ part: 'Widget', desc: 'Seed', qty: 1 }]
      })
      .select('id')
      .single();
    if (orderError || !orderRow) throw orderError || new Error('Failed to create order');
    orderId = orderRow.id;
  });

  it('enforces tier gating for orders select and insert', async () => {
    await setCompanyTier(companyId, 'starter');

    const { data: deniedRows, error: deniedError } = await adminAuth
      .from('orders')
      .select('id')
      .eq('company_id', companyId)
      .is('deleted_at', null);
    expect(deniedError).toBeNull();
    expect((deniedRows || []).length).toBe(0);

    const { error: insertError } = await adminAuth.from('orders').insert({
      company_id: companyId,
      created_by: adminUserId,
      to_email: 'orders2@test.local',
      reply_to_email: 'orders2@test.local',
      subject: 'Denied Order',
      contact_name: 'Denied',
      notes: 'Should fail',
      line_items: [{ part: 'Widget', desc: 'Denied', qty: 2 }]
    });
    expect(insertError).not.toBeNull();

    await setCompanyTier(companyId, 'business');
  });

  it('allows viewers to read orders at Business tier', async () => {
    await setCompanyTier(companyId, 'business');
    const { data, error } = await viewerAuth
      .from('orders')
      .select('id')
      .eq('company_id', companyId)
      .is('deleted_at', null);
    expect(error).toBeNull();
    expect((data || []).length).toBeGreaterThan(0);
  });

  it('allows members to create orders at Business tier', async () => {
    await setCompanyTier(companyId, 'business');
    const { data, error } = await memberAuth
      .from('orders')
      .insert({
        company_id: companyId,
        created_by: memberUserId,
        to_email: `member-${uniqueSuffix}@test.local`,
        reply_to_email: `member-${uniqueSuffix}@test.local`,
        subject: 'Member Order',
        contact_name: 'Member',
        notes: 'Member order test',
        line_items: [{ part: 'Bolt', desc: 'Member', qty: 3 }]
      })
      .select('id');
    expect(error).toBeNull();
    expect((data || []).length).toBe(1);
  });

  it('enforces permissions for order delete and restore', async () => {
    await setCompanyTier(companyId, 'business');

    const { data: deniedDelete, error: deniedDeleteError } = await viewerAuth.rpc('soft_delete_order', {
      p_order_id: orderId
    });
    expect(deniedDeleteError).toBeNull();
    expect(deniedDelete?.success).toBe(false);
    expect(String(deniedDelete?.error || '')).toMatch(/permission/i);

    const { data: adminDelete, error: adminDeleteError } = await adminAuth.rpc('soft_delete_order', {
      p_order_id: orderId
    });
    expect(adminDeleteError).toBeNull();
    expect(adminDelete?.success).toBe(true);

    const { data: deniedRestore, error: deniedRestoreError } = await viewerAuth.rpc('restore_order', {
      p_order_id: orderId
    });
    expect(deniedRestoreError).toBeNull();
    expect(deniedRestore?.success).toBe(false);
    expect(String(deniedRestore?.error || '')).toMatch(/permission/i);

    const { data: adminRestore, error: adminRestoreError } = await adminAuth.rpc('restore_order', {
      p_order_id: orderId
    });
    expect(adminRestoreError).toBeNull();
    expect(adminRestore?.success).toBe(true);
  });

  it('enforces tier gating for order recipients', async () => {
    await setCompanyTier(companyId, 'starter');
    const { error: deniedInsert } = await adminAuth.from('order_recipients').insert({
      company_id: companyId,
      email: `recipient-${uniqueSuffix}@test.local`,
      name: 'Test Recipient'
    });
    expect(deniedInsert).not.toBeNull();

    await setCompanyTier(companyId, 'business');
    const { error: allowedInsert } = await adminAuth.from('order_recipients').insert({
      company_id: companyId,
      email: `recipient-allowed-${uniqueSuffix}@test.local`,
      name: 'Allowed Recipient'
    });
    expect(allowedInsert).toBeNull();
  });

  it('requires Business tier for send-order endpoint', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data: sessionData } = await adminAuth.auth.getSession();
    const token = sessionData?.session?.access_token;
    expect(token).toBeTruthy();

    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-order`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({
        to: 'orders@test.local',
        subject: 'Send Order',
        text: 'Order body',
        company_id: companyId
      })
    });
    const data = await res.json();
    expect(res.status).toBe(403);
    expect(String(data?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
  });
});
