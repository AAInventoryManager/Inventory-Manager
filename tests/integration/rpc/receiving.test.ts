import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  setCompanyTierForTests,
  TEST_PASSWORD
} from '../../setup/test-utils';

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

async function setRolePermission(roleName: string, permissionKey: string, value: boolean) {
  const { data, error } = await adminClient
    .from('role_configurations')
    .select('permissions')
    .eq('role_name', roleName)
    .single();
  if (error) throw error;
  const permissions = data?.permissions && typeof data.permissions === 'object' ? data.permissions : {};
  const nextPermissions = { ...permissions, [permissionKey]: value };
  const { error: updateError } = await adminClient
    .from('role_configurations')
    .update({ permissions: nextPermissions, updated_at: new Date().toISOString() })
    .eq('role_name', roleName);
  if (updateError) throw updateError;
}

describe('RPC: receipt-based receiving', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let viewerAuth: SupabaseClient;
  let adminUserId: string;
  let viewerUserId: string;

  beforeAll(async () => {
    const slug = `receiving-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Receiving RPC Test',
        slug,
        settings: { test: true, tier: 'enterprise' },
        company_type: 'test'
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;
    await setCompanyTierForTests(companyId, 'enterprise', 'receiving RPC tests');

    const adminEmail = uniqueEmail('receiving-admin');
    const viewerEmail = uniqueEmail('receiving-viewer');

    adminUserId = await createTestUser(adminEmail);
    viewerUserId = await createTestUser(viewerEmail);

    const { error: adminInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminInsertError) throw adminInsertError;

    const { error: viewerInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: viewerUserId,
      role: 'viewer',
      assigned_admin_id: adminUserId
    });
    if (viewerInsertError) throw viewerInsertError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    viewerAuth = await createAuthenticatedClient(viewerEmail, TEST_PASSWORD);

    await setRolePermission('admin', 'receiving:create', true);
    await setRolePermission('admin', 'receiving:edit', true);
    await setRolePermission('admin', 'receiving:approve', true);
    await setRolePermission('admin', 'receiving:void', true);
  });

  async function createItem(quantity = 10): Promise<string> {
    const { data, error } = await adminClient
      .from('inventory_items')
      .insert({
        company_id: companyId,
        name: `Receipt Item ${uniqueSuffix}-${Math.random().toString(16).slice(2)}`,
        description: 'Receipt item',
        quantity,
        reorder_enabled: true,
        created_by: adminUserId
      })
      .select('id')
      .single();
    if (error || !data) throw error || new Error('Failed to create item');
    return data.id;
  }

  async function getItemQuantity(itemId: string): Promise<number> {
    const { data, error } = await adminClient
      .from('inventory_items')
      .select('quantity')
      .eq('id', itemId)
      .single();
    if (error || !data) throw error || new Error('Failed to fetch item quantity');
    return data.quantity;
  }

  it('draft receipts do not affect inventory', async () => {
    const itemId = await createItem(10);
    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    expect(receipt?.success).toBe(true);

    const receiptId = receipt?.receipt_id;
    const { data: line, error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 4,
      p_rejected_qty: 1,
      p_rejection_reason: 'Damaged in transit'
    });
    expect(lineError).toBeNull();
    expect(line?.success).toBe(true);

    const quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(10);
  });

  it('completing a receipt increments inventory correctly', async () => {
    const itemId = await createItem(5);
    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    expect(receipt?.success).toBe(true);

    const receiptId = receipt?.receipt_id;
    const { error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 3,
      p_rejected_qty: 0
    });
    expect(lineError).toBeNull();

    const { error: submitError } = await adminAuth.rpc('transition_receipt_status', {
      p_receipt_id: receiptId,
      p_next_status: 'pending'
    });
    expect(submitError).toBeNull();

    const { data: completed, error: completeError } = await adminAuth.rpc('complete_receipt', {
      p_receipt_id: receiptId
    });
    expect(completeError).toBeNull();
    expect(completed?.success).toBe(true);

    const quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(8);
  });

  it('partial receipt lines increment only received qty', async () => {
    const itemId = await createItem(7);
    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    const receiptId = receipt?.receipt_id;

    const { error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 2,
      p_rejected_qty: 5,
      p_rejection_reason: 'Damaged'
    });
    expect(lineError).toBeNull();

    const { error: submitError } = await adminAuth.rpc('transition_receipt_status', {
      p_receipt_id: receiptId,
      p_next_status: 'pending'
    });
    expect(submitError).toBeNull();

    const { error: completeError } = await adminAuth.rpc('complete_receipt', { p_receipt_id: receiptId });
    expect(completeError).toBeNull();

    const quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(9);
  });

  it('voiding a receipt does not change inventory', async () => {
    const itemId = await createItem(6);
    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    const receiptId = receipt?.receipt_id;

    const { error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 4,
      p_rejected_qty: 0
    });
    expect(lineError).toBeNull();

    const { error: submitError } = await adminAuth.rpc('transition_receipt_status', {
      p_receipt_id: receiptId,
      p_next_status: 'pending'
    });
    expect(submitError).toBeNull();

    const { error: completeError } = await adminAuth.rpc('complete_receipt', { p_receipt_id: receiptId });
    expect(completeError).toBeNull();
    let quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(10);

    const { data: voided, error: voidError } = await adminAuth.rpc('void_receipt', {
      p_receipt_id: receiptId,
      p_reason: 'Voiding receipt for audit correction'
    });
    expect(voidError).toBeNull();
    expect(voided?.success).toBe(true);

    quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(10);
  });

  it('prevents double completion and double void', async () => {
    const itemId = await createItem(12);
    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    const receiptId = receipt?.receipt_id;

    const { error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 3,
      p_rejected_qty: 0
    });
    expect(lineError).toBeNull();

    const { error: submitError } = await adminAuth.rpc('transition_receipt_status', {
      p_receipt_id: receiptId,
      p_next_status: 'pending'
    });
    expect(submitError).toBeNull();

    const { error: completeError } = await adminAuth.rpc('complete_receipt', { p_receipt_id: receiptId });
    expect(completeError).toBeNull();
    let quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(15);

    const { data: completedAgain } = await adminAuth.rpc('complete_receipt', {
      p_receipt_id: receiptId
    });
    expect(completedAgain?.already_in_state).toBe(true);
    quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(15);

    const { error: voidError } = await adminAuth.rpc('void_receipt', {
      p_receipt_id: receiptId,
      p_reason: 'Voiding receipt for audit correction'
    });
    expect(voidError).toBeNull();
    quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(15);

    const { data: voidedAgain } = await adminAuth.rpc('void_receipt', {
      p_receipt_id: receiptId,
      p_reason: 'Voiding receipt for audit correction'
    });
    expect(voidedAgain?.already_in_state).toBe(true);
    quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(15);
  });

  it('rejects unauthorized users', async () => {
    const itemId = await createItem(9);
    const { data: deniedCreate, error: deniedCreateError } = await viewerAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(deniedCreateError).toBeNull();
    expect(deniedCreate?.success).toBe(false);
    expect(String(deniedCreate?.error || '')).toMatch(/permission/i);

    const { data: receipt, error: receiptError } = await adminAuth.rpc('create_receipt', {
      p_company_id: companyId,
      p_purchase_order_id: null
    });
    expect(receiptError).toBeNull();
    const receiptId = receipt?.receipt_id;

    const { error: lineError } = await adminAuth.rpc('add_receipt_line', {
      p_receipt_id: receiptId,
      p_item_id: itemId,
      p_received_qty: 2,
      p_rejected_qty: 0
    });
    expect(lineError).toBeNull();

    const { error: submitError } = await adminAuth.rpc('transition_receipt_status', {
      p_receipt_id: receiptId,
      p_next_status: 'pending'
    });
    expect(submitError).toBeNull();

    const { data: deniedComplete, error: deniedCompleteError } = await viewerAuth.rpc('complete_receipt', {
      p_receipt_id: receiptId
    });
    expect(deniedCompleteError).toBeNull();
    expect(deniedComplete?.success).toBe(false);
    expect(String(deniedComplete?.error || '')).toMatch(/permission/i);

    const quantity = await getItemQuantity(itemId);
    expect(quantity).toBe(9);
  });
});
