import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
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

async function createTestCompany(): Promise<string> {
  const slug = `jobs-${uniqueSuffix}`;
  const { data, error } = await adminClient
    .from('companies')
    .insert({
      name: 'Jobs Test Company',
      slug,
      settings: { test: true },
      company_type: 'test'
    })
    .select('id')
    .single();
  if (error || !data) throw error || new Error('Failed to create company');
  return data.id;
}

async function resetCompanyData(companyId: string): Promise<void> {
  const { error: jobError } = await adminClient.from('jobs').delete().eq('company_id', companyId);
  if (jobError) throw jobError;

  const { error: itemError } = await adminClient.from('inventory_items').delete().eq('company_id', companyId);
  if (itemError) throw itemError;
}

async function createInventoryItem(
  companyId: string,
  name: string,
  quantity: number,
  createdBy: string
): Promise<string> {
  const { data, error } = await adminClient
    .from('inventory_items')
    .insert({
      company_id: companyId,
      name,
      quantity,
      created_by: createdBy
    })
    .select('id')
    .single();
  if (error || !data) throw error || new Error('Failed to create inventory item');
  return data.id;
}

async function getItemQuantity(itemId: string): Promise<number> {
  const { data, error } = await adminClient.from('inventory_items').select('quantity').eq('id', itemId).single();
  if (error || !data) throw error || new Error('Failed to load inventory item');
  return Number(data.quantity || 0);
}

async function fetchJobEvents(jobId: string): Promise<string[]> {
  const { data, error } = await adminClient
    .from('audit_log')
    .select('new_values')
    .eq('table_name', 'job_events')
    .eq('record_id', jobId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data || [])
    .map(row => (row as { new_values?: { event_name?: string } })?.new_values?.event_name)
    .filter((name): name is string => Boolean(name));
}

describe.sequential('Jobs RPCs', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let memberAuth: SupabaseClient;
  let outsiderAuth: SupabaseClient;
  let adminUserId: string;
  let memberUserId: string;

  beforeAll(async () => {
    companyId = await createTestCompany();

    const adminEmail = uniqueEmail('jobs-admin');
    adminUserId = await createTestUser(adminEmail);
    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);

    const memberEmail = uniqueEmail('jobs-member');
    memberUserId = await createTestUser(memberEmail);
    memberAuth = await createAuthenticatedClient(memberEmail, TEST_PASSWORD);

    const outsiderEmail = uniqueEmail('jobs-outsider');
    await createTestUser(outsiderEmail);
    outsiderAuth = await createAuthenticatedClient(outsiderEmail, TEST_PASSWORD);

    const { error: adminMemberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminMemberError) throw adminMemberError;

    const { error: memberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: memberUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (memberError) throw memberError;
  });

  beforeEach(async () => {
    await resetCompanyData(companyId);
  });

  it('draft jobs do not affect inventory', async () => {
    const itemId = await createInventoryItem(companyId, `Item Draft ${uniqueSuffix}`, 5, adminUserId);

    const { data: jobId, error: jobError } = await memberAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Draft Job',
      p_notes: null
    });
    expect(jobError).toBeNull();
    expect(jobId).toBeTruthy();

    const { error: bomError } = await memberAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemId,
      p_qty_planned: 3
    });
    expect(bomError).toBeNull();

    const qty = await getItemQuantity(itemId);
    expect(qty).toBe(5);
  });

  it('blocks approval when availability is insufficient', async () => {
    const itemId = await createInventoryItem(companyId, `Item Block ${uniqueSuffix}`, 2, adminUserId);

    const { data: jobId } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Blocked Job',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemId,
      p_qty_planned: 3
    });

    const { error } = await adminAuth.rpc('approve_job', { p_job_id: jobId });
    expect(error).not.toBeNull();
    expect(error?.message || '').toContain('Insufficient inventory');
  });

  it('reserves inventory on approval and prevents double reservation', async () => {
    const itemId = await createInventoryItem(companyId, `Item Reserve ${uniqueSuffix}`, 5, adminUserId);

    const { data: jobId1 } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job One',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId1,
      p_item_id: itemId,
      p_qty_planned: 3
    });

    const approve1 = await adminAuth.rpc('approve_job', { p_job_id: jobId1 });
    expect(approve1.error).toBeNull();

    const approve1Again = await adminAuth.rpc('approve_job', { p_job_id: jobId1 });
    expect(approve1Again.error).toBeNull();

    const { data: jobId2 } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job Two',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId2,
      p_item_id: itemId,
      p_qty_planned: 3
    });

    const approve2 = await adminAuth.rpc('approve_job', { p_job_id: jobId2 });
    expect(approve2.error).not.toBeNull();

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId2,
      p_item_id: itemId,
      p_qty_planned: 2
    });

    const approve2Fixed = await adminAuth.rpc('approve_job', { p_job_id: jobId2 });
    expect(approve2Fixed.error).toBeNull();
    const qty = await getItemQuantity(itemId);
    expect(qty).toBe(5);
  });

  it('completes job with variance, consumes inventory, and releases reservations', async () => {
    const itemId = await createInventoryItem(companyId, `Item Complete ${uniqueSuffix}`, 10, adminUserId);

    const { data: jobId } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job Complete',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemId,
      p_qty_planned: 6
    });

    const approve = await adminAuth.rpc('approve_job', { p_job_id: jobId });
    expect(approve.error).toBeNull();

    const complete = await adminAuth.rpc('complete_job', {
      p_job_id: jobId,
      p_actuals: [{ item_id: itemId, qty_used: 4 }]
    });
    expect(complete.error).toBeNull();

    const qty = await getItemQuantity(itemId);
    expect(qty).toBe(6);

    const { data: jobId2 } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job After',
      p_notes: null
    });
    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId2,
      p_item_id: itemId,
      p_qty_planned: 6
    });
    const approve2 = await adminAuth.rpc('approve_job', { p_job_id: jobId2 });
    expect(approve2.error).toBeNull();
  });

  it('void releases reservations without consumption', async () => {
    const itemId = await createInventoryItem(companyId, `Item Void ${uniqueSuffix}`, 5, adminUserId);

    const { data: jobId } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job Void',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemId,
      p_qty_planned: 4
    });

    const approve = await adminAuth.rpc('approve_job', { p_job_id: jobId });
    expect(approve.error).toBeNull();

    const voided = await adminAuth.rpc('void_job', { p_job_id: jobId });
    expect(voided.error).toBeNull();

    const qty = await getItemQuantity(itemId);
    expect(qty).toBe(5);

    const { data: jobId2 } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job After Void',
      p_notes: null
    });
    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId2,
      p_item_id: itemId,
      p_qty_planned: 5
    });
    const approve2 = await adminAuth.rpc('approve_job', { p_job_id: jobId2 });
    expect(approve2.error).toBeNull();
  });

  it('requires actuals for all BOM items', async () => {
    const itemA = await createInventoryItem(companyId, `Item A ${uniqueSuffix}`, 5, adminUserId);
    const itemB = await createInventoryItem(companyId, `Item B ${uniqueSuffix}`, 5, adminUserId);

    const { data: jobId } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job Actuals',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemA,
      p_qty_planned: 1
    });
    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemB,
      p_qty_planned: 1
    });

    await adminAuth.rpc('approve_job', { p_job_id: jobId });

    const { error } = await adminAuth.rpc('complete_job', {
      p_job_id: jobId,
      p_actuals: [{ item_id: itemA, qty_used: 1 }]
    });
    expect(error).not.toBeNull();
    expect(error?.message || '').toContain('Missing actuals');
  });

  it('rejects unauthorized callers', async () => {
    const { error } = await outsiderAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Unauthorized Job',
      p_notes: null
    });
    expect(error).not.toBeNull();
  });

  it('emits audit events for job lifecycle and inventory actions', async () => {
    const itemId = await createInventoryItem(companyId, `Item Audit ${uniqueSuffix}`, 5, adminUserId);

    const { data: jobId } = await adminAuth.rpc('create_job', {
      p_company_id: companyId,
      p_name: 'Job Audit',
      p_notes: null
    });

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId,
      p_item_id: itemId,
      p_qty_planned: 2
    });

    await adminAuth.rpc('approve_job', { p_job_id: jobId });

    await adminAuth.rpc('complete_job', {
      p_job_id: jobId,
      p_actuals: [{ item_id: itemId, qty_used: 2 }]
    });

    const events = await fetchJobEvents(String(jobId));
    expect(events).toContain('job_created');
    expect(events).toContain('job_approved');
    expect(events).toContain('job_inventory_reserved');
    expect(events).toContain('job_completed');
    expect(events).toContain('job_inventory_consumed');
  });
});
