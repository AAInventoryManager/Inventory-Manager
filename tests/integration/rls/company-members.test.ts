import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { getClient, getCompanyId, TEST_COMPANIES } from '../../setup/test-utils';

describe('RLS: company_members', () => {
  let adminClientAuth: SupabaseClient;
  let otherAdminClient: SupabaseClient;
  let mainCompanyId: string;

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN');
    otherAdminClient = await getClient('OTHER_ADMIN');
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN.slug);
  });

  it('admin can see members in own company', async () => {
    const { data, error } = await adminClientAuth
      .from('company_members')
      .select('company_id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect((data || []).length).toBeGreaterThan(0);
  });

  it('other company admin cannot see main company members', async () => {
    const { data, error } = await otherAdminClient
      .from('company_members')
      .select('company_id')
      .eq('company_id', mainCompanyId);

    expect(error).toBeNull();
    expect(data || []).toHaveLength(0);
  });
});
