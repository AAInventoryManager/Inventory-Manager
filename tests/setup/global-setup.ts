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
    let lastError: Error | null = null;

    // Retry user creation up to 3 times
    for (let attempt = 1; attempt <= 3 && !userId; attempt++) {
      // Try to create user
      const { data: created, error } = await adminClient.auth.admin.createUser({
        email: user.email,
        password: TEST_PASSWORD,
        email_confirm: true
      });

      userId = created?.user?.id;

      // If creation succeeded, we're done
      if (userId) break;

      // Check if user already exists
      const isAlreadyExists = error?.message?.toLowerCase().includes('already') ||
                               error?.message?.toLowerCase().includes('exists');

      if (isAlreadyExists) {
        // Try to get existing user from auth
        try {
          userId = await getAuthUserIdByEmail(user.email);
          break;
        } catch {
          // User not found in auth, will retry creation
          lastError = new Error(`User allegedly exists but not found: ${user.email}`);
        }
      } else if (error) {
        lastError = error;
      } else {
        lastError = new Error(`createUser returned null for ${user.email}`);
      }

      // Wait before retry
      if (attempt < 3 && !userId) {
        await new Promise(r => setTimeout(r, 1000 * attempt));
      }
    }

    if (!userId) {
      throw new Error(`Failed to create/find user ${user.email} after 3 attempts. Last error: ${lastError?.message || 'unknown'}`);
    }
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
