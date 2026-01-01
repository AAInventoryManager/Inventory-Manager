import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  adminClient,
  createAuthenticatedClient,
  getAuthUserIdByEmail,
  TEST_PASSWORD,
  TEST_USERS
} from '../../setup/test-utils';

const uniqueSuffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;

describe('RPC: set_company_environment', () => {
  let companyId: string;
  let superAuth: SupabaseClient;
  let adminAuth: SupabaseClient;
  let superUserId: string;

  beforeAll(async () => {
    const slug = `env-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: `Env Test ${uniqueSuffix}`,
        slug,
        settings: { test: true },
        company_type: 'production'
      })
      .select('id')
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    superAuth = await createAuthenticatedClient(TEST_USERS.SUPER, TEST_PASSWORD);
    adminAuth = await createAuthenticatedClient(TEST_USERS.ADMIN, TEST_PASSWORD);
    superUserId = await getAuthUserIdByEmail(TEST_USERS.SUPER);
    const { error: cleanupError } = await adminClient
      .from('company_members')
      .delete()
      .eq('user_id', superUserId);
    if (cleanupError) throw cleanupError;
    const { error: superMemberError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: superUserId,
      role: 'admin',
      is_super_user: true,
      assigned_admin_id: superUserId
    });
    if (superMemberError) throw superMemberError;
  });

  it('blocks non-super_user callers', async () => {
    const { data, error } = await adminAuth.rpc('set_company_environment', {
      p_company_id: companyId,
      p_environment: 'test'
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
  });

  it('updates environment and emits audit event', async () => {
    const { data, error } = await superAuth.rpc('set_company_environment', {
      p_company_id: companyId,
      p_environment: 'test'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(true);
    expect(data?.environment).toBe('test');

    const { data: company, error: fetchError } = await adminClient
      .from('companies')
      .select('company_type')
      .eq('id', companyId)
      .single();
    if (fetchError) throw fetchError;
    expect(company?.company_type).toBe('test');

    const { data: auditRows, error: auditError } = await adminClient
      .from('audit_log')
      .select('new_values')
      .eq('company_id', companyId)
      .eq('table_name', 'company_events')
      .order('created_at', { ascending: false })
      .limit(10);
    if (auditError) throw auditError;
    const auditRow = (auditRows || []).find(
      row => row?.new_values?.event_name === 'company_environment_changed'
    );
    expect(auditRow).toBeTruthy();
    expect(auditRow?.new_values?.actor_user_id).toBe(superUserId);
    expect(auditRow?.new_values?.from_environment).toBe('production');
    expect(auditRow?.new_values?.to_environment).toBe('test');
  });

  it('is idempotent when setting the same environment', async () => {
    const { data, error } = await superAuth.rpc('set_company_environment', {
      p_company_id: companyId,
      p_environment: 'test'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(true);
    expect(data?.changed).toBe(false);
  });

  it('rejects invalid environments', async () => {
    const { data, error } = await superAuth.rpc('set_company_environment', {
      p_company_id: companyId,
      p_environment: 'sandbox'
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
  });
});
