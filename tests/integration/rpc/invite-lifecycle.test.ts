import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { createHash } from 'crypto';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  SUPABASE_ANON_KEY,
  SUPABASE_URL,
  TEST_PASSWORD
} from '../../setup/test-utils';

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

function uniqueEmail(prefix: string) {
  return `${prefix}+${uniqueSuffix}@test.local`;
}

function hashEmail(email: string) {
  return createHash('sha256').update(email.trim().toLowerCase()).digest('hex');
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

describe('RPC: invite lifecycle', () => {
  let companyId: string;
  let adminUserId: string;
  let memberUserId: string;
  let adminClientAuth: SupabaseClient;
  let memberClientAuth: SupabaseClient;
  let anonClient: SupabaseClient;

  beforeAll(async () => {
    const slug = `invite-lifecycle-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Invite Lifecycle Test',
        slug,
        settings: { test: true },
        company_type: 'test'
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('invite-admin');
    const memberEmail = uniqueEmail('invite-member');

    adminUserId = await createTestUser(adminEmail);
    memberUserId = await createTestUser(memberEmail);

    const { error: adminMemberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminMemberError) throw adminMemberError;

    const { error: memberMemberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: memberUserId,
      role: 'member',
      assigned_admin_id: adminUserId
    });
    if (memberMemberError) throw memberMemberError;

    adminClientAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    memberClientAuth = await createAuthenticatedClient(memberEmail, TEST_PASSWORD);
    anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { autoRefreshToken: false, persistSession: false }
    });
  });

  it('enforces one pending invite per company+email and denies non-admin sends', async () => {
    const email = uniqueEmail('invitee');
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

    const { data: sendData, error: sendError } = await adminClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: email,
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(sendError).toBeNull();
    expect(sendData?.success).toBe(true);

    const { data: duplicateData, error: duplicateError } = await adminClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: email,
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(duplicateError).toBeNull();
    expect(duplicateData?.success).toBe(false);

    const { data: deniedData, error: deniedError } = await memberClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: uniqueEmail('member-invite'),
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(deniedError).toBeNull();
    expect(deniedData?.success).toBe(false);
  });

  it('increments resend_count and rejects unauthorized resend', async () => {
    const email = uniqueEmail('resend');
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

    const { data: sendData, error: sendError } = await adminClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: email,
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(sendError).toBeNull();
    const inviteId = String(sendData?.invite_id || '');
    expect(inviteId).toBeTruthy();

    const { data: resendData, error: resendError } = await adminClientAuth.rpc('resend_company_invite', {
      p_invite_id: inviteId
    });
    expect(resendError).toBeNull();
    expect(resendData?.success).toBe(true);
    expect(resendData?.resend_count).toBe(1);

    const { data: inviteRow, error: inviteError } = await adminClient
      .from('company_invites')
      .select('resend_count')
      .eq('id', inviteId)
      .single();
    if (inviteError) throw inviteError;
    expect(inviteRow?.resend_count).toBe(1);

    const { data: deniedData, error: deniedError } = await memberClientAuth.rpc('resend_company_invite', {
      p_invite_id: inviteId
    });
    expect(deniedError).toBeNull();
    expect(deniedData?.success).toBe(false);
  });

  it('accepts invite, deletes invite row, and keeps analytics events', async () => {
    const email = uniqueEmail('accept');
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const inviteeUserId = await createTestUser(email);
    const inviteeClient = await createAuthenticatedClient(email, TEST_PASSWORD);

    const { data: sendData, error: sendError } = await adminClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: email,
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(sendError).toBeNull();
    const inviteId = String(sendData?.invite_id || '');
    expect(inviteId).toBeTruthy();

    const { data: acceptData, error: acceptError } = await inviteeClient.rpc('accept_company_invite', {
      p_invite_id: inviteId
    });
    expect(acceptError).toBeNull();
    expect(acceptData?.success).toBe(true);

    const { data: inviteRow, error: inviteRowError } = await adminClient
      .from('company_invites')
      .select('id')
      .eq('id', inviteId)
      .maybeSingle();
    expect(inviteRowError).toBeNull();
    expect(inviteRow).toBeNull();

    const emailHash = hashEmail(email);
    const { data: acceptedEvents, error: acceptedError } = await adminClient
      .from('invite_events')
      .select('latency_seconds')
      .eq('company_id', companyId)
      .eq('invite_email_hash', emailHash)
      .eq('event_type', 'invite_accepted');
    if (acceptedError) throw acceptedError;
    expect((acceptedEvents || []).length).toBeGreaterThan(0);
    expect(acceptedEvents?.[0]?.latency_seconds ?? null).not.toBeNull();

    const { data: sentEvents, error: sentError } = await adminClient
      .from('invite_events')
      .select('id')
      .eq('company_id', companyId)
      .eq('invite_email_hash', emailHash)
      .eq('event_type', 'invite_sent');
    if (sentError) throw sentError;
    expect((sentEvents || []).length).toBeGreaterThan(0);

    const { data: membership, error: membershipError } = await adminClient
      .from('company_members')
      .select('company_id')
      .eq('user_id', inviteeUserId)
      .single();
    if (membershipError) throw membershipError;
    expect(membership?.company_id).toBe(companyId);
  });

  it('allows anon acceptance for an existing user', async () => {
    const email = uniqueEmail('anon-accept');
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const inviteeUserId = await createTestUser(email);

    const { data: sendData, error: sendError } = await adminClientAuth.rpc('send_company_invite', {
      p_company_id: companyId,
      p_email: email,
      p_role: 'member',
      p_expires_at: expiresAt
    });
    expect(sendError).toBeNull();
    const inviteId = String(sendData?.invite_id || '');
    expect(inviteId).toBeTruthy();

    const { data: acceptData, error: acceptError } = await anonClient.rpc('accept_company_invite', {
      p_invite_id: inviteId
    });
    expect(acceptError).toBeNull();
    expect(acceptData?.success).toBe(true);

    const { data: membership, error: membershipError } = await adminClient
      .from('company_members')
      .select('company_id')
      .eq('user_id', inviteeUserId)
      .single();
    if (membershipError) throw membershipError;
    expect(membership?.company_id).toBe(companyId);
  });

  it('expires pending invites once and emits analytics', async () => {
    const emailA = uniqueEmail('expired-a');
    const emailB = uniqueEmail('expired-b');
    const sentAt = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
    const expiresAt = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { error: insertError } = await adminClient.from('company_invites').insert([
      {
        company_id: companyId,
        email: emailA.toLowerCase(),
        role: 'member',
        invited_by_user_id: adminUserId,
        sent_at: sentAt,
        last_sent_at: sentAt,
        resend_count: 0,
        expires_at: expiresAt,
        status: 'pending'
      },
      {
        company_id: companyId,
        email: emailB.toLowerCase(),
        role: 'member',
        invited_by_user_id: adminUserId,
        sent_at: sentAt,
        last_sent_at: sentAt,
        resend_count: 0,
        expires_at: expiresAt,
        status: 'pending'
      }
    ]);
    if (insertError) throw insertError;

    const { data: expiredCount, error: expiredError } = await adminClient.rpc('expire_company_invites');
    expect(expiredError).toBeNull();
    // RPC expires ALL pending invites globally, so count may include leftovers from other runs
    expect(expiredCount).toBeGreaterThanOrEqual(2);

    const { data: events, error: eventsError } = await adminClient
      .from('invite_events')
      .select('invite_email_hash')
      .eq('company_id', companyId)
      .eq('event_type', 'invite_expired')
      .in('invite_email_hash', [hashEmail(emailA), hashEmail(emailB)]);
    if (eventsError) throw eventsError;
    expect((events || []).length).toBe(2);

    // Verify our specific invites are now expired
    const { data: inviteStatuses, error: statusError } = await adminClient
      .from('company_invites')
      .select('status')
      .eq('company_id', companyId)
      .in('email', [emailA.toLowerCase(), emailB.toLowerCase()]);
    if (statusError) throw statusError;
    expect(inviteStatuses?.every(i => i.status === 'expired')).toBe(true);

    const { data: expiredAgain, error: expiredAgainError } = await adminClient.rpc('expire_company_invites');
    expect(expiredAgainError).toBeNull();
    // No new pending invites should be expired on second run
    expect(expiredAgain).toBe(0);
  });
});
