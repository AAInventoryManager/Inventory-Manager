import { adminClient, TEST_USERS, TEST_COMPANIES, TEST_PASSWORD, getAuthUserIdByEmail } from './test-utils';
import { TEST_INVENTORY_ITEMS } from '../fixtures/inventory';

interface TestUserDef {
  email: string;
  role: 'admin' | 'member' | 'viewer';
  companyKey: keyof typeof TEST_COMPANIES;
  isSuperUser?: boolean;
}

const testUsers: TestUserDef[] = [
  { email: TEST_USERS.SUPER, role: 'admin', companyKey: 'MAIN', isSuperUser: true },
  { email: TEST_USERS.ADMIN, role: 'admin', companyKey: 'MAIN' },
  { email: TEST_USERS.MEMBER, role: 'member', companyKey: 'MAIN' },
  { email: TEST_USERS.VIEWER, role: 'viewer', companyKey: 'MAIN' },
  { email: TEST_USERS.OTHER_ADMIN, role: 'admin', companyKey: 'OTHER' }
];

export default async function globalSetup() {
  const companyIds: Record<string, string> = {};
  const userIds: Record<string, string> = {};

  for (const [key, company] of Object.entries(TEST_COMPANIES)) {
    const { data, error } = await adminClient
      .from('companies')
      .upsert(
        { name: company.name, slug: company.slug, settings: { test: true }, company_type: 'test' },
        { onConflict: 'slug' }
      )
      .select()
      .single();
    if (error || !data) throw error || new Error(`Failed to upsert company ${company.slug}`);
    companyIds[key] = data.id;
  }

  for (const user of testUsers) {
    let userId: string | undefined;

    // First, try to find existing user
    try {
      userId = await getAuthUserIdByEmail(user.email);
    } catch {
      // User doesn't exist, that's fine
    }

    // If user exists, just update password
    if (userId) {
      // User exists, update password
    } else {
      // User doesn't exist, create new
      // First clean up any stale profile data
      await adminClient.from('profiles').delete().eq('email', user.email);

      const { data: created, error } = await adminClient.auth.admin.createUser({
        email: user.email,
        password: TEST_PASSWORD,
        email_confirm: true
      });

      if (error) throw new Error(`Failed to create user ${user.email}: ${error.message}`);
      if (!created?.user?.id) throw new Error(`No user ID returned for ${user.email}`);
      userId = created.user.id;
    }

    // Update user password to ensure it's correct
    userIds[user.email] = userId;
    const { error: updateError } = await adminClient.auth.admin.updateUserById(userId, {
      password: TEST_PASSWORD,
      email_confirm: true
    });
    if (updateError) throw updateError;

    await adminClient
      .from('profiles')
      .upsert(
        { user_id: userId, email: user.email, first_name: '', last_name: '' },
        { onConflict: 'user_id' }
      );

    const companyId = companyIds[user.companyKey];
    const assignedAdminId = user.role === 'admin' ? userId : userIds[TEST_USERS.ADMIN] || userId;

    const memberPayload = {
      company_id: companyId,
      user_id: userId,
      role: user.role,
      is_super_user: !!user.isSuperUser,
      assigned_admin_id: assignedAdminId
    };
    const { error: cleanupError } = await adminClient
      .from('company_members')
      .delete()
      .eq('user_id', userId);
    if (cleanupError) throw cleanupError;
    const { error: insertError } = await adminClient
      .from('company_members')
      .insert(memberPayload);
    if (insertError) throw insertError;
  }

  for (const item of TEST_INVENTORY_ITEMS) {
    const companyId = companyIds[item.company];
    const createdBy = item.company === 'OTHER' ? userIds[TEST_USERS.OTHER_ADMIN] : userIds[TEST_USERS.ADMIN];

    await adminClient
      .from('inventory_items')
      .upsert(
        {
          company_id: companyId,
          name: item.name,
          quantity: item.quantity,
          low_stock_qty: item.low_stock_qty || null,
          sku: item.sku,
          created_by: createdBy
        },
        { onConflict: 'company_id,sku' }
      );
  }
}
