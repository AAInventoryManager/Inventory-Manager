import { adminClient, TEST_COMPANIES, TEST_USERS, clearClientCache } from './test-utils';

export default async function globalTeardown() {
  try {
    const slugs = Object.values(TEST_COMPANIES).map(c => c.slug);
    const { data: companies } = await adminClient
      .from('companies')
      .select('id')
      .in('slug', slugs);

    const companyIds = (companies || []).map(c => c.id);

    if (companyIds.length) {
      await adminClient.from('action_metrics').delete().in('company_id', companyIds);
      await adminClient.from('inventory_transactions').delete().in('company_id', companyIds);
      await adminClient.from('inventory_items').delete().in('company_id', companyIds);
      await adminClient.from('inventory_categories').delete().in('company_id', companyIds);
      await adminClient.from('inventory_locations').delete().in('company_id', companyIds);
      await adminClient.from('inventory_snapshots').delete().in('company_id', companyIds);
      await adminClient.from('order_recipients').delete().in('company_id', companyIds);
      await adminClient.from('orders').delete().in('company_id', companyIds);
      await adminClient.from('role_change_requests').delete().in('company_id', companyIds);
      await adminClient.from('audit_log').delete().in('company_id', companyIds);
      await adminClient.from('invitations').delete().in('company_id', companyIds);
      await adminClient.from('company_members').delete().in('company_id', companyIds);
      await adminClient.from('companies').delete().in('id', companyIds);
    }

    const testEmails = Object.values(TEST_USERS);
    const { data: authUsers, error } = await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (!error) {
      for (const user of authUsers.users) {
        if (user.email && testEmails.includes(user.email)) {
          await adminClient.auth.admin.deleteUser(user.id);
        }
      }
    }
  } catch (error) {
    console.warn('Global teardown encountered an error:', error);
  } finally {
    clearClientCache();
  }
}
