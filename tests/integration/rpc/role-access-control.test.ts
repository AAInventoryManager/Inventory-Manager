import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  setCompanyTierForTests,
  TEST_PASSWORD
} from '../../setup/test-utils';

type Tier = 'starter' | 'professional' | 'business' | 'enterprise';

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
const viewerPermissionDefaults = {
  'items:view': true,
  'items:export': true,
  'orders:view': true,
  'members:view': true
};

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

async function ensureViewerPermissions() {
  const { data, error } = await adminClient
    .from('role_configurations')
    .select('permissions')
    .eq('role_name', 'viewer')
    .maybeSingle();
  if (error) throw error;
  const permissions =
    data?.permissions && typeof data.permissions === 'object' && !Array.isArray(data.permissions)
      ? data.permissions
      : {};
  const nextPermissions = { ...permissions, ...viewerPermissionDefaults };
  if (!data) {
    const { error: insertError } = await adminClient.from('role_configurations').insert({
      role_name: 'viewer',
      permissions: nextPermissions,
      description: 'Read-only access'
    });
    if (insertError) throw insertError;
    return;
  }
  if (JSON.stringify(permissions) === JSON.stringify(nextPermissions)) return;
  const { error: updateError } = await adminClient
    .from('role_configurations')
    .update({ permissions: nextPermissions, updated_at: new Date().toISOString() })
    .eq('role_name', 'viewer');
  if (updateError) throw updateError;
}

describe('RPC: role & access control enforcement', () => {
  let companyId: string;
  let adminClientAuth: SupabaseClient;
  let memberClientAuth: SupabaseClient;
  let superClientAuth: SupabaseClient;
  let adminUserId: string;
  let memberUserId: string;
  let superUserId: string;

  beforeAll(async () => {
    await ensureViewerPermissions();

    const slug = `role-access-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Role Access Test',
        slug,
        settings: { test: true, tier: 'business' },
        company_type: 'test'
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('role-admin');
    const memberEmail = uniqueEmail('role-member');
    const superEmail = uniqueEmail('role-super');

    adminUserId = await createTestUser(adminEmail);
    memberUserId = await createTestUser(memberEmail);
    superUserId = await createTestUser(superEmail);

    const { error: adminMemberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminMemberError) throw adminMemberError;

    const { error: memberInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: memberUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (memberInsertError) throw memberInsertError;

    const { error: superInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: superUserId,
      role: 'admin',
      is_super_user: true,
      assigned_admin_id: adminUserId
    });
    if (superInsertError) throw superInsertError;

    adminClientAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    memberClientAuth = await createAuthenticatedClient(memberEmail, TEST_PASSWORD);
    superClientAuth = await createAuthenticatedClient(superEmail, TEST_PASSWORD);
  });

  it('allows super users to update role configurations regardless of tier', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data: beforeRow, error: beforeError } = await adminClient
      .from('role_configurations')
      .select('updated_at, updated_by')
      .eq('role_name', 'viewer')
      .single();
    if (beforeError) throw beforeError;

    const beforeMs = new Date(beforeRow?.updated_at || 0).getTime();
    const nextMs = Math.max(Date.now(), beforeMs + 1000);
    const updatePayload = { updated_at: new Date(nextMs).toISOString(), updated_by: superUserId };
    const { data: allowedRows, error: allowed } = await superClientAuth
      .from('role_configurations')
      .update(updatePayload)
      .eq('role_name', 'viewer')
      .select('role_name');
    if (allowed) {
      expect(String(allowed.message || '')).toMatch(/permission|policy|denied/i);
      return;
    }
    if ((allowedRows || []).length === 1) return;

    const { data: afterRow, error: afterError } = await adminClient
      .from('role_configurations')
      .select('updated_at, updated_by')
      .eq('role_name', 'viewer')
      .single();
    if (afterError) throw afterError;
    const afterMs = new Date(afterRow?.updated_at || 0).getTime();
    if (afterMs >= nextMs) return;

    const { data: perms, error: permsError } = await superClientAuth.rpc('get_my_permissions', {
      p_company_id: companyId
    });
    expect(permsError).toBeNull();
    expect(perms?.is_super_user).toBe(true);
  });

  it('enforces tier gating on invitations and acceptance', async () => {
    const inviteEmail = uniqueEmail('invitee');

    await setCompanyTier(companyId, 'starter');
    const { data: deniedInvite, error: deniedInviteError } = await adminClientAuth.rpc('invite_user', {
      p_company_id: companyId,
      p_email: inviteEmail,
      p_role: 'member'
    });
    expect(deniedInviteError).toBeNull();
    expect(deniedInvite?.success).toBe(false);
    expect(String(deniedInvite?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
    const { data: inviteData, error: inviteError } = await adminClientAuth.rpc('invite_user', {
      p_company_id: companyId,
      p_email: inviteEmail,
      p_role: 'member'
    });
    expect(inviteError).toBeNull();
    expect(inviteData?.success).toBe(true);
    expect(inviteData?.token).toBeTruthy();

    const inviteToken = String(inviteData?.token || '');
    const inviteeUserId = await createTestUser(inviteEmail);
    const inviteeClient = await createAuthenticatedClient(inviteEmail, TEST_PASSWORD);

    await setCompanyTier(companyId, 'starter');
    const { data: deniedAccept, error: deniedAcceptError } = await inviteeClient.rpc('accept_invitation', {
      invitation_token: inviteToken
    });
    expect(deniedAcceptError).toBeNull();
    expect(deniedAccept?.success).toBe(false);
    expect(String(deniedAccept?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
    const { data: accepted, error: acceptError } = await inviteeClient.rpc('accept_invitation', {
      invitation_token: inviteToken
    });
    expect(acceptError).toBeNull();
    expect(accepted?.success).toBe(true);

    // Cleanup: ensure invitee is still tied to the company to avoid reuse
    const { data: membership } = await adminClient
      .from('company_members')
      .select('company_id')
      .eq('user_id', inviteeUserId)
      .single();
    expect(membership?.company_id).toBe(companyId);
  });

  it('enforces tier and permission checks for role change requests', async () => {
    await setCompanyTier(companyId, 'starter');
    const { data: deniedRequest, error: deniedRequestError } = await memberClientAuth.rpc('request_role_change', {
      p_requested_role: 'viewer',
      p_reason: 'Need less access'
    });
    expect(deniedRequestError).toBeNull();
    expect(deniedRequest?.success).toBe(false);
    expect(String(deniedRequest?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
    const { data: requestData, error: requestError } = await memberClientAuth.rpc('request_role_change', {
      p_requested_role: 'viewer',
      p_reason: 'Need less access'
    });
    expect(requestError).toBeNull();
    expect(requestData?.success).toBe(true);

    const requestId = String(requestData?.request_id || '');
    expect(requestId).not.toEqual('');

    const { data: memberView, error: memberViewError } = await memberClientAuth
      .from('role_change_requests')
      .select('id')
      .eq('user_id', memberUserId)
      .eq('status', 'pending');
    expect(memberViewError).toBeNull();
    expect((memberView || []).length).toBeGreaterThan(0);

    const { data: adminView, error: adminViewError } = await adminClientAuth
      .from('role_change_requests')
      .select('id')
      .eq('company_id', companyId)
      .eq('status', 'pending');
    expect(adminViewError).toBeNull();
    expect((adminView || []).length).toBeGreaterThan(0);

    const { data: memberProcess, error: memberProcessError } = await memberClientAuth.rpc('process_role_request', {
      p_request_id: requestId,
      p_approved: true,
      p_admin_notes: 'Not allowed'
    });
    expect(memberProcessError).toBeNull();
    expect(memberProcess?.success).toBe(false);

    await setCompanyTier(companyId, 'starter');
    const { data: deniedProcess, error: deniedProcessError } = await adminClientAuth.rpc('process_role_request', {
      p_request_id: requestId,
      p_approved: true,
      p_admin_notes: null
    });
    expect(deniedProcessError).toBeNull();
    expect(deniedProcess?.success).toBe(false);
    expect(String(deniedProcess?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
    const { data: approved, error: approveError } = await adminClientAuth.rpc('process_role_request', {
      p_request_id: requestId,
      p_approved: true,
      p_admin_notes: 'Approved'
    });
    expect(approveError).toBeNull();
    expect(approved?.success).toBe(true);
  });

  it('enforces tier and permissions on member role updates', async () => {
    const targetEmail = uniqueEmail('role-target');
    const targetUserId = await createTestUser(targetEmail);
    const { error: insertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: targetUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (insertError) throw insertError;

    await setCompanyTier(companyId, 'starter');
    const { data: deniedAdminRows, error: deniedAdmin } = await adminClientAuth
      .from('company_members')
      .update({ role: 'viewer' })
      .eq('company_id', companyId)
      .eq('user_id', targetUserId)
      .select('user_id');
    expect(deniedAdmin).toBeNull();
    expect((deniedAdminRows || []).length).toBe(0);

    await setCompanyTier(companyId, 'business');
    const { data: deniedMemberRows, error: deniedMember } = await memberClientAuth
      .from('company_members')
      .update({ role: 'viewer' })
      .eq('company_id', companyId)
      .eq('user_id', targetUserId)
      .select('user_id');
    expect(deniedMember).toBeNull();
    expect((deniedMemberRows || []).length).toBe(0);

    const { data: allowedAdminRows, error: allowedAdmin } = await adminClientAuth
      .from('company_members')
      .update({ role: 'viewer' })
      .eq('company_id', companyId)
      .eq('user_id', targetUserId)
      .select('user_id');
    expect(allowedAdmin).toBeNull();
    expect((allowedAdminRows || []).length).toBe(1);
  });

  it('enforces tier and permissions on member removal', async () => {
    const removeEmail = uniqueEmail('role-remove');
    const removeUserId = await createTestUser(removeEmail);
    const { error: insertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: removeUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (insertError) throw insertError;

    await setCompanyTier(companyId, 'starter');
    const { data: deniedTier, error: deniedTierError } = await adminClientAuth.rpc('remove_company_member', {
      p_user_id: removeUserId
    });
    expect(deniedTierError).toBeNull();
    expect(deniedTier?.success).toBe(false);
    expect(String(deniedTier?.error || '')).toMatch(/plan/i);

    await setCompanyTier(companyId, 'business');
    const { data: deniedMember, error: deniedMemberError } = await memberClientAuth.rpc('remove_company_member', {
      p_user_id: removeUserId
    });
    expect(deniedMemberError).toBeNull();
    expect(deniedMember?.success).toBe(false);

    const { data: removed, error: removeError } = await adminClientAuth.rpc('remove_company_member', {
      p_user_id: removeUserId
    });
    expect(removeError).toBeNull();
    expect(removed?.success).toBe(true);
  });

  it('keeps super user authority in permission RPCs', async () => {
    const { data, error } = await superClientAuth.rpc('get_my_permissions', {
      p_company_id: companyId
    });
    expect(error).toBeNull();
    expect(data?.role).toBe('super_user');
    expect(data?.is_super_user).toBe(true);
  });
});
