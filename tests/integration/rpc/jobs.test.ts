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

async function fetchActiveShortfalls(jobId: string): Promise<Map<string, number>> {
  const { data, error } = await adminClient
    .from('shortfalls')
    .select('item_id,qty_missing,status')
    .eq('job_id', jobId)
    .eq('status', 'active');
  if (error) throw error;
  const map = new Map<string, number>();
  (data || []).forEach(row => {
    const itemId = String((row as { item_id?: string }).item_id || '').trim();
    const qty = Number((row as { qty_missing?: number }).qty_missing || 0);
    if (itemId && Number.isFinite(qty)) map.set(itemId, qty);
  });
  return map;
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

  it('blocks approval and records shortfall when job is not fulfillable', async () => {
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

    const { data, error } = await adminAuth.rpc('approve_job', {
      p_job_id: jobId,
      p_was_fulfillable: false
    });
    expect(error).toBeNull();
    expect(data?.blocked).toBe(true);

    const { data: job } = await adminClient.from('jobs').select('status').eq('id', jobId).single();
    expect(job?.status).toBe('draft');

    const shortfalls = await fetchActiveShortfalls(jobId);
    expect(shortfalls.get(itemId)).toBe(1);
  });

  it('reserves inventory on approval and keeps approvals idempotent', async () => {
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

    const approve1 = await adminAuth.rpc('approve_job', {
      p_job_id: jobId1,
      p_was_fulfillable: true
    });
    expect(approve1.error).toBeNull();

    const approve1Again = await adminAuth.rpc('approve_job', {
      p_job_id: jobId1,
      p_was_fulfillable: true
    });
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

    const approve2 = await adminAuth.rpc('approve_job', {
      p_job_id: jobId2,
      p_was_fulfillable: false
    });
    expect(approve2.error).toBeNull();
    expect(approve2.data?.blocked).toBe(true);

    const shortfallsBefore = await fetchActiveShortfalls(jobId2);
    expect(shortfallsBefore.get(itemId)).toBe(1);

    await adminAuth.rpc('upsert_job_bom_line', {
      p_job_id: jobId2,
      p_item_id: itemId,
      p_qty_planned: 2
    });

    const approve2Fixed = await adminAuth.rpc('approve_job', {
      p_job_id: jobId2,
      p_was_fulfillable: false
    });
    expect(approve2Fixed.error).toBeNull();
    expect(approve2Fixed.data?.status).toBe('approved');
    const qty = await getItemQuantity(itemId);
    expect(qty).toBe(5);

    const shortfallsAfter = await fetchActiveShortfalls(jobId2);
    expect(shortfallsAfter.size).toBe(0);
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

    const approve = await adminAuth.rpc('approve_job', {
      p_job_id: jobId,
      p_was_fulfillable: true
    });
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
    const approve2 = await adminAuth.rpc('approve_job', {
      p_job_id: jobId2,
      p_was_fulfillable: true
    });
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

    const approve = await adminAuth.rpc('approve_job', {
      p_job_id: jobId,
      p_was_fulfillable: true
    });
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
    const approve2 = await adminAuth.rpc('approve_job', {
      p_job_id: jobId2,
      p_was_fulfillable: true
    });
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

    await adminAuth.rpc('approve_job', { p_job_id: jobId, p_was_fulfillable: true });

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

    await adminAuth.rpc('approve_job', { p_job_id: jobId, p_was_fulfillable: true });

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

  // =========================================================================
  // jobs_approval_inventory_consistency test suite
  // Tests for the approval guardrail behavior per governance spec
  // =========================================================================

  describe('jobs_approval_inventory_consistency', () => {
    it('TEST 1 - reseed resolves shortage and allows approval', async () => {
      // Create item with insufficient quantity
      const itemId = await createInventoryItem(companyId, `Item Reseed ${uniqueSuffix}`, 2, adminUserId);

      // Create job requiring more than available
      const { data: jobId } = await adminAuth.rpc('create_job', {
        p_company_id: companyId,
        p_name: 'Job Reseed Test',
        p_notes: null
      });

      await adminAuth.rpc('upsert_job_bom_line', {
        p_job_id: jobId,
        p_item_id: itemId,
        p_qty_planned: 5
      });

      // Reseed inventory to resolve shortage
      await adminClient.from('inventory_items').update({ quantity: 10 }).eq('id', itemId);

      // Approval should now succeed
      const { error: secondError } = await adminAuth.rpc('approve_job', {
        p_job_id: jobId,
        p_was_fulfillable: false
      });
      expect(secondError).toBeNull();

      // Verify job is approved
      const { data: job } = await adminClient.from('jobs').select('status').eq('id', jobId).single();
      expect(job?.status).toBe('approved');
    });

    it('TEST 2 - inventory reduction causes regression and blocks approval', async () => {
      // Create item with sufficient quantity
      const itemId = await createInventoryItem(companyId, `Item Reduce ${uniqueSuffix}`, 10, adminUserId);

      // Create fulfillable job
      const { data: jobId } = await adminAuth.rpc('create_job', {
        p_company_id: companyId,
        p_name: 'Job Reduce Test',
        p_notes: null
      });

      await adminAuth.rpc('upsert_job_bom_line', {
        p_job_id: jobId,
        p_item_id: itemId,
        p_qty_planned: 5
      });

      // Reduce inventory before approval
      await adminClient.from('inventory_items').update({ quantity: 3 }).eq('id', itemId);

      // Approval should fail due to insufficient inventory
      const { data, error } = await adminAuth.rpc('approve_job', {
        p_job_id: jobId,
        p_was_fulfillable: true
      });
      expect(error).toBeNull();
      expect(data?.blocked).toBe(true);
      expect(data?.reason).toBe('inventory_changed');
    });

    it('TEST 3 - concurrent user conflict blocks second approval', async () => {
      // Create item with limited quantity
      const itemId = await createInventoryItem(companyId, `Item Concurrent ${uniqueSuffix}`, 5, adminUserId);

      // User A creates and prepares a job
      const { data: jobIdA } = await adminAuth.rpc('create_job', {
        p_company_id: companyId,
        p_name: 'Job A Concurrent',
        p_notes: null
      });

      await adminAuth.rpc('upsert_job_bom_line', {
        p_job_id: jobIdA,
        p_item_id: itemId,
        p_qty_planned: 4
      });

      // User B (member) creates a competing job
      const { data: jobIdB } = await memberAuth.rpc('create_job', {
        p_company_id: companyId,
        p_name: 'Job B Concurrent',
        p_notes: null
      });

      await memberAuth.rpc('upsert_job_bom_line', {
        p_job_id: jobIdB,
        p_item_id: itemId,
        p_qty_planned: 4
      });

      // User B approves first (reserves the inventory)
      const { error: approveB } = await adminAuth.rpc('approve_job', {
        p_job_id: jobIdB,
        p_was_fulfillable: true
      });
      expect(approveB).toBeNull();

      // User A tries to approve - should fail (only 1 unit left available)
      const { data: approveA, error: approveAError } = await adminAuth.rpc('approve_job', {
        p_job_id: jobIdA,
        p_was_fulfillable: true
      });
      expect(approveAError).toBeNull();
      expect(approveA?.blocked).toBe(true);
      expect(approveA?.reason).toBe('inventory_changed');
    });

    it('TEST 4 - unrelated inventory change does not block approval', async () => {
      // Create two separate items
      const itemA = await createInventoryItem(companyId, `Item A Unrelated ${uniqueSuffix}`, 10, adminUserId);
      const itemB = await createInventoryItem(companyId, `Item B Unrelated ${uniqueSuffix}`, 10, adminUserId);

      // Create job for Item A only
      const { data: jobId } = await adminAuth.rpc('create_job', {
        p_company_id: companyId,
        p_name: 'Job Unrelated Test',
        p_notes: null
      });

      await adminAuth.rpc('upsert_job_bom_line', {
        p_job_id: jobId,
        p_item_id: itemA,
        p_qty_planned: 5
      });

      // Modify unrelated Item B (reduce to zero even)
      await adminClient.from('inventory_items').update({ quantity: 0 }).eq('id', itemB);

      // Approval should still succeed (Item B is unrelated)
      const { error } = await adminAuth.rpc('approve_job', {
        p_job_id: jobId,
        p_was_fulfillable: true
      });
      expect(error).toBeNull();

      // Verify job is approved
      const { data: job } = await adminClient.from('jobs').select('status').eq('id', jobId).single();
      expect(job?.status).toBe('approved');
    });
  });
});
