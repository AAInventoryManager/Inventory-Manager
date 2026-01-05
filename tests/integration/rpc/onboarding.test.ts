import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  getClient,
  TEST_PASSWORD,
  TEST_USERS
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
  const slug = `onboarding-${uniqueSuffix}`;
  const { data, error } = await adminClient
    .from('companies')
    .insert({
      name: 'Onboarding Test Company',
      slug,
      settings: { test: true },
      company_type: 'test'
    })
    .select('id')
    .single();
  if (error || !data) throw error || new Error('Failed to create company');
  return data.id;
}

async function resetCompanyState(companyId: string): Promise<void> {
  const { error: updateError } = await adminClient
    .from('companies')
    .update({ onboarding_state: 'UNINITIALIZED', settings: {} })
    .eq('id', companyId);
  if (updateError) throw updateError;

  const { error: locationError } = await adminClient
    .from('company_locations')
    .delete()
    .eq('company_id', companyId);
  if (locationError) throw locationError;

  const { error: inviteError } = await adminClient
    .from('invitations')
    .delete()
    .eq('company_id', companyId);
  if (inviteError) throw inviteError;
}

async function setProfileSettings(companyId: string): Promise<void> {
  const settings = {
    primary_contact_email: uniqueEmail('owner'),
    timezone: 'America/Chicago'
  };
  const { error } = await adminClient
    .from('companies')
    .update({ settings })
    .eq('id', companyId);
  if (error) throw error;
}

async function createLocation(companyId: string): Promise<void> {
  const { error } = await adminClient.from('company_locations').insert({
    company_id: companyId,
    name: 'Primary Warehouse',
    location_type: 'warehouse',
    google_formatted_address: '123 Main St, Austin, TX 78701, USA',
    google_place_id: null,
    google_address_components: null,
    is_active: true
  });
  if (error) throw error;
}

async function createInvite(companyId: string): Promise<void> {
  const { error } = await adminClient.from('invitations').insert({
    company_id: companyId,
    email: uniqueEmail('invitee'),
    role: 'member'
  });
  if (error) throw error;
}

async function fetchOnboardingEvents(companyId: string) {
  const { data, error } = await adminClient
    .from('audit_log')
    .select('id,new_values,user_id,created_at')
    .eq('company_id', companyId)
    .eq('table_name', 'onboarding_events')
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) throw error;
  return (data || []).filter(row => row?.new_values?.event_name === 'onboarding_state_changed');
}

describe.sequential('Onboarding state RPCs', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let superAuth: SupabaseClient;
  let outsiderAuth: SupabaseClient;
  let adminUserId: string;
  let superUserId: string;

  beforeAll(async () => {
    companyId = await createTestCompany();

    const adminEmail = uniqueEmail('onboarding-admin');
    adminUserId = await createTestUser(adminEmail);

    const { error: memberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (memberError) throw memberError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);

    const outsiderEmail = uniqueEmail('onboarding-outsider');
    await createTestUser(outsiderEmail);
    outsiderAuth = await createAuthenticatedClient(outsiderEmail, TEST_PASSWORD);

    superAuth = await getClient('SUPER');
    superUserId = await getAuthUserIdByEmail(TEST_USERS.SUPER);
  });

  beforeEach(async () => {
    await resetCompanyState(companyId);
  });

  it('returns onboarding state for members', async () => {
    const { error: updateError } = await adminClient
      .from('companies')
      .update({ onboarding_state: 'SUBSCRIPTION_ACTIVE' })
      .eq('id', companyId);
    expect(updateError).toBeNull();

    const { data, error } = await adminAuth.rpc('get_onboarding_state', { p_company_id: companyId });
    expect(error).toBeNull();
    expect(String(data)).toBe('SUBSCRIPTION_ACTIVE');
  });

  it('blocks non-members from reading onboarding state', async () => {
    const { data, error } = await outsiderAuth.rpc('get_onboarding_state', { p_company_id: companyId });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
  });

  it('advances sequentially with prerequisites and emits audit events', async () => {
    const before = await fetchOnboardingEvents(companyId);

    let result = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'SUBSCRIPTION_ACTIVE'
    });
    expect(result.error).toBeNull();
    expect(String(result.data)).toBe('SUBSCRIPTION_ACTIVE');

    await setProfileSettings(companyId);
    result = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'COMPANY_PROFILE_COMPLETE'
    });
    expect(result.error).toBeNull();
    expect(String(result.data)).toBe('COMPANY_PROFILE_COMPLETE');

    await createLocation(companyId);
    result = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'LOCATIONS_CONFIGURED'
    });
    expect(result.error).toBeNull();
    expect(String(result.data)).toBe('LOCATIONS_CONFIGURED');

    await createInvite(companyId);
    result = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'USERS_INVITED'
    });
    expect(result.error).toBeNull();
    expect(String(result.data)).toBe('USERS_INVITED');

    result = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'ONBOARDING_COMPLETE'
    });
    expect(result.error).toBeNull();
    expect(String(result.data)).toBe('ONBOARDING_COMPLETE');

    const after = await fetchOnboardingEvents(companyId);
    expect(after.length - before.length).toBe(5);

    const latest = after[0];
    expect(latest?.new_values?.event_name).toBe('onboarding_state_changed');
    expect(latest?.new_values?.from_state).toBe('USERS_INVITED');
    expect(latest?.new_values?.to_state).toBe('ONBOARDING_COMPLETE');
    expect(latest?.new_values?.actor_user_id).toBe(adminUserId);
  });

  it('rejects invalid transitions for non-super users', async () => {
    await setProfileSettings(companyId);
    await createLocation(companyId);
    await createInvite(companyId);

    const { data, error } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'USERS_INVITED'
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error?.message || '').toMatch(/invalid transition/i);
  });

  it('blocks advancement when prerequisites are missing', async () => {
    const { error: subError } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'SUBSCRIPTION_ACTIVE'
    });
    expect(subError).toBeNull();

    const { data: profileData, error: profileError } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'COMPANY_PROFILE_COMPLETE'
    });
    expect(profileData).toBeNull();
    expect(profileError).not.toBeNull();
    expect(profileError?.message || '').toMatch(/profile/i);

    await setProfileSettings(companyId);
    const { error: profileOkError } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'COMPANY_PROFILE_COMPLETE'
    });
    expect(profileOkError).toBeNull();

    const { data: locData, error: locError } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'LOCATIONS_CONFIGURED'
    });
    expect(locData).toBeNull();
    expect(locError).not.toBeNull();
    expect(locError?.message || '').toMatch(/locations/i);
  });

  it('allows super users to fast-forward when prerequisites are met', async () => {
    await setProfileSettings(companyId);
    await createLocation(companyId);
    await createInvite(companyId);

    const { data, error } = await superAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'ONBOARDING_COMPLETE'
    });
    expect(error).toBeNull();
    expect(String(data)).toBe('ONBOARDING_COMPLETE');

    const events = await fetchOnboardingEvents(companyId);
    const latest = events[0];
    expect(latest?.new_values?.from_state).toBe('UNINITIALIZED');
    expect(latest?.new_values?.to_state).toBe('ONBOARDING_COMPLETE');
    expect(latest?.new_values?.actor_user_id).toBe(superUserId);
  });

  it('no-ops when target matches current state', async () => {
    const { error: subError } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'SUBSCRIPTION_ACTIVE'
    });
    expect(subError).toBeNull();

    const before = await fetchOnboardingEvents(companyId);

    const { data, error } = await adminAuth.rpc('advance_onboarding_state', {
      p_company_id: companyId,
      p_target_state: 'SUBSCRIPTION_ACTIVE'
    });
    expect(error).toBeNull();
    expect(String(data)).toBe('SUBSCRIPTION_ACTIVE');

    const after = await fetchOnboardingEvents(companyId);
    expect(after.length).toBe(before.length);
  });

  it('auto-advances to the furthest valid state and emits per-step events', async () => {
    await setProfileSettings(companyId);
    await createLocation(companyId);
    await createInvite(companyId);

    const before = await fetchOnboardingEvents(companyId);

    const { data, error } = await adminAuth.rpc('auto_advance_onboarding', { p_company_id: companyId });
    expect(error).toBeNull();
    expect(String(data)).toBe('ONBOARDING_COMPLETE');

    const after = await fetchOnboardingEvents(companyId);
    expect(after.length - before.length).toBe(5);
  });
});
