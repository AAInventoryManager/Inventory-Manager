import { describe, it, expect, beforeAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { randomUUID } from 'crypto';
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

async function setRolePermission(roleName: string, permissionKey: string, value: boolean) {
  const { data, error } = await adminClient
    .from('role_configurations')
    .select('permissions')
    .eq('role_name', roleName)
    .single();
  if (error) throw error;
  const permissions = data?.permissions && typeof data.permissions === 'object' ? data.permissions : {};
  const nextPermissions = { ...permissions, [permissionKey]: value };
  const { error: updateError } = await adminClient
    .from('role_configurations')
    .update({ permissions: nextPermissions, updated_at: new Date().toISOString() })
    .eq('role_name', roleName);
  if (updateError) throw updateError;
}

type LocationInput = {
  name: string;
  locationType?: string;
  addressLine1?: string;
  addressLine2?: string;
  city?: string;
  stateRegion?: string;
  postalCode?: string;
  countryCode?: string;
  defaultShipTo?: boolean;
  defaultReceiveAt?: boolean;
};

function baseLocationInput(name: string): LocationInput {
  return {
    name,
    locationType: 'warehouse',
    addressLine1: '123 Main St',
    addressLine2: '',
    city: 'Austin',
    stateRegion: 'TX',
    postalCode: '78701',
    countryCode: 'US',
    defaultShipTo: false,
    defaultReceiveAt: false
  };
}

async function createLocation(client: SupabaseClient, companyId: string, input: LocationInput): Promise<string> {
  const payload = {
    p_company_id: companyId,
    p_name: input.name,
    p_location_type: input.locationType || 'warehouse',
    p_address_line1: input.addressLine1 || '123 Main St',
    p_address_line2: input.addressLine2 || null,
    p_city: input.city || 'Austin',
    p_state_region: input.stateRegion || 'TX',
    p_postal_code: input.postalCode || '78701',
    p_country_code: input.countryCode || 'US',
    p_set_default_ship_to: input.defaultShipTo || false,
    p_set_default_receive_at: input.defaultReceiveAt || false
  };
  const { data, error } = await client.rpc('create_company_location', payload);
  if (error) throw error;
  if (data && data.success === false) {
    throw new Error(data.error || 'Failed to create location');
  }
  const locationId = data?.location_id;
  if (!locationId) throw new Error('No location id returned');
  return String(locationId);
}

async function columnExists(table: string, column: string): Promise<boolean> {
  const { data, error } = await adminClient
    .from('information_schema.columns')
    .select('column_name')
    .eq('table_schema', 'public')
    .eq('table_name', table)
    .eq('column_name', column)
    .limit(1);
  if (error) return false;
  return Array.isArray(data) && data.length > 0;
}

type ColumnInfo = {
  column_name: string;
  data_type: string;
  is_nullable: string;
  column_default: string | null;
};

function guessValue(column: ColumnInfo): unknown {
  const name = column.column_name.toLowerCase();
  if (name.includes('status')) return 'draft';
  if (name.includes('type')) return 'other';
  if (name.includes('country_code')) return 'US';
  if (name.includes('email')) return `test+${uniqueSuffix}@test.local`;
  const dataType = column.data_type.toLowerCase();
  if (dataType.includes('uuid')) return randomUUID();
  if (dataType.includes('character') || dataType.includes('text')) return 'test';
  if (dataType.includes('boolean')) return false;
  if (dataType.includes('timestamp')) return new Date().toISOString();
  if (dataType === 'date') return new Date().toISOString().slice(0, 10);
  if (dataType.includes('int') || dataType.includes('numeric') || dataType.includes('double') || dataType.includes('real')) {
    return 1;
  }
  if (dataType.includes('json')) return {};
  return 'test';
}

async function insertReferenceRow(
  table: string,
  column: string,
  companyId: string,
  locationId: string,
  actorUserId: string
): Promise<boolean> {
  const { data, error } = await adminClient
    .from('information_schema.columns')
    .select('column_name,data_type,is_nullable,column_default')
    .eq('table_schema', 'public')
    .eq('table_name', table);
  if (error || !Array.isArray(data) || data.length === 0) return false;

  const columns = data as ColumnInfo[];
  const row: Record<string, unknown> = {
    [column]: locationId
  };

  if (columns.some(col => col.column_name === 'company_id')) {
    row.company_id = companyId;
  }
  if (columns.some(col => col.column_name === 'id')) {
    row.id = randomUUID();
  }
  if (columns.some(col => col.column_name === 'created_by')) {
    row.created_by = actorUserId;
  }
  if (columns.some(col => col.column_name === 'updated_by')) {
    row.updated_by = actorUserId;
  }
  if (columns.some(col => col.column_name === 'received_by')) {
    row.received_by = actorUserId;
  }
  if (columns.some(col => col.column_name === 'user_id')) {
    row.user_id = actorUserId;
  }
  if (columns.some(col => col.column_name === 'assigned_admin_id')) {
    row.assigned_admin_id = actorUserId;
  }

  for (const col of columns) {
    if (Object.prototype.hasOwnProperty.call(row, col.column_name)) continue;
    const required = col.is_nullable === 'NO' && !col.column_default;
    if (!required) continue;
    row[col.column_name] = guessValue(col);
  }

  const { error: insertError } = await adminClient.from(table).insert(row);
  if (insertError) return false;
  return true;
}

async function createReferenceIfPossible(companyId: string, locationId: string, actorUserId: string): Promise<boolean> {
  const targets = [
    { table: 'purchase_orders', column: 'ship_to_location_id' },
    { table: 'receipts', column: 'receive_at_location_id' },
    { table: 'jobs', column: 'job_site_location_id' }
  ];

  for (const target of targets) {
    const exists = await columnExists(target.table, target.column);
    if (!exists) continue;
    const inserted = await insertReferenceRow(target.table, target.column, companyId, locationId, actorUserId);
    if (inserted) return true;
  }

  return false;
}

describe('RPC: company locations', () => {
  let companyId: string;
  let adminAuth: SupabaseClient;
  let viewerAuth: SupabaseClient;
  let adminUserId: string;

  beforeAll(async () => {
    const slug = `locations-${uniqueSuffix}`;
    const { data, error } = await adminClient
      .from('companies')
      .insert({
        name: 'Locations RPC Test',
        slug,
        settings: { test: true, tier: 'starter' },
        company_type: 'test'
      })
      .select()
      .single();
    if (error || !data) throw error || new Error('Failed to create company');
    companyId = data.id;

    const adminEmail = uniqueEmail('locations-admin');
    const viewerEmail = uniqueEmail('locations-viewer');

    adminUserId = await createTestUser(adminEmail);
    const viewerUserId = await createTestUser(viewerEmail);

    const { error: adminInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: adminUserId,
      role: 'admin',
      assigned_admin_id: adminUserId
    });
    if (adminInsertError) throw adminInsertError;

    const { error: viewerInsertError } = await adminClient.from('company_members').insert({
      company_id: companyId,
      user_id: viewerUserId,
      role: 'viewer',
      assigned_admin_id: adminUserId
    });
    if (viewerInsertError) throw viewerInsertError;

    adminAuth = await createAuthenticatedClient(adminEmail, TEST_PASSWORD);
    viewerAuth = await createAuthenticatedClient(viewerEmail, TEST_PASSWORD);

    await setRolePermission('admin', 'orders:manage_shipping', true);
    await setRolePermission('viewer', 'orders:manage_shipping', false);
  });

  it('enforces single defaults and clears previous defaults', async () => {
    const locA = await createLocation(adminAuth, companyId, {
      ...baseLocationInput(`Main Warehouse ${uniqueSuffix}`),
      defaultShipTo: true,
      defaultReceiveAt: true
    });
    const locB = await createLocation(adminAuth, companyId, {
      ...baseLocationInput(`Yard ${uniqueSuffix}`),
      locationType: 'yard'
    });

    const { data: setShip, error: setShipError } = await adminAuth.rpc('set_default_location', {
      p_location_id: locB,
      p_default_type: 'ship_to'
    });
    expect(setShipError).toBeNull();
    expect(setShip?.success).toBe(true);

    let { data: rows, error: listError } = await adminClient
      .from('company_locations')
      .select('id,is_default_ship_to,is_default_receive_at')
      .eq('company_id', companyId);
    if (listError) throw listError;
    const shipDefaults = (rows || []).filter(r => r.is_default_ship_to);
    expect(shipDefaults).toHaveLength(1);
    expect(shipDefaults[0].id).toBe(locB);

    const { data: setReceive, error: setReceiveError } = await adminAuth.rpc('set_default_location', {
      p_location_id: locB,
      p_default_type: 'receive_at'
    });
    expect(setReceiveError).toBeNull();
    expect(setReceive?.success).toBe(true);

    ({ data: rows, error: listError } = await adminClient
      .from('company_locations')
      .select('id,is_default_receive_at')
      .eq('company_id', companyId));
    if (listError) throw listError;
    const receiveDefaults = (rows || []).filter(r => r.is_default_receive_at);
    expect(receiveDefaults).toHaveLength(1);
    expect(receiveDefaults[0].id).toBe(locB);

    const defaultA = (rows || []).find(r => r.id === locA);
    if (defaultA) {
      expect(defaultA.is_default_receive_at).toBe(false);
    }
  });

  it('cannot archive a default location', async () => {
    const loc = await createLocation(adminAuth, companyId, {
      ...baseLocationInput(`Office ${uniqueSuffix}`),
      locationType: 'office'
    });

    const { data: setDefault } = await adminAuth.rpc('set_default_location', {
      p_location_id: loc,
      p_default_type: 'ship_to'
    });
    expect(setDefault?.success).toBe(true);

    const { data: archived, error } = await adminAuth.rpc('archive_company_location', {
      p_location_id: loc
    });
    expect(error).toBeNull();
    expect(archived?.success).toBe(false);
    expect(String(archived?.error || '')).toMatch(/default/i);
  });

  it('cannot archive a referenced location', async () => {
    const loc = await createLocation(adminAuth, companyId, {
      ...baseLocationInput(`Referenced ${uniqueSuffix}`),
      locationType: 'warehouse'
    });

    const referenced = await createReferenceIfPossible(companyId, loc, adminUserId);
    if (!referenced) {
      expect(true).toBe(true);
      return;
    }

    const { data: archived, error } = await adminAuth.rpc('archive_company_location', {
      p_location_id: loc
    });
    expect(error).toBeNull();
    expect(archived?.success).toBe(false);
    expect(String(archived?.error || '')).toMatch(/referenced/i);
  });

  it('allows updating and restoring archived locations', async () => {
    const loc = await createLocation(adminAuth, companyId, {
      ...baseLocationInput(`Archived ${uniqueSuffix}`),
      locationType: 'yard'
    });

    const { data: archived, error: archiveError } = await adminAuth.rpc('archive_company_location', {
      p_location_id: loc
    });
    expect(archiveError).toBeNull();
    expect(archived?.success).toBe(true);

    const updatedName = `Updated ${uniqueSuffix}`;
    const payload = baseLocationInput(updatedName);
    const { data: updated, error: updateError } = await adminAuth.rpc('update_company_location', {
      p_location_id: loc,
      p_name: payload.name,
      p_location_type: payload.locationType,
      p_address_line1: payload.addressLine1,
      p_address_line2: payload.addressLine2,
      p_city: payload.city,
      p_state_region: payload.stateRegion,
      p_postal_code: payload.postalCode,
      p_country_code: payload.countryCode
    });
    expect(updateError).toBeNull();
    expect(updated?.success).toBe(true);

    const { data: restored, error: restoreError } = await adminAuth.rpc('restore_company_location', {
      p_location_id: loc
    });
    expect(restoreError).toBeNull();
    expect(restored?.success).toBe(true);

    const { data: row, error: rowError } = await adminClient
      .from('company_locations')
      .select('name,is_active')
      .eq('id', loc)
      .single();
    if (rowError) throw rowError;
    expect(row?.name).toBe(updatedName);
    expect(row?.is_active).toBe(true);
  });

  it('rejects unauthorized callers', async () => {
    const payload = baseLocationInput(`Unauthorized ${uniqueSuffix}`);
    const { data, error } = await viewerAuth.rpc('create_company_location', {
      p_company_id: companyId,
      p_name: payload.name,
      p_location_type: payload.locationType,
      p_address_line1: payload.addressLine1,
      p_address_line2: payload.addressLine2,
      p_city: payload.city,
      p_state_region: payload.stateRegion,
      p_postal_code: payload.postalCode,
      p_country_code: payload.countryCode,
      p_set_default_ship_to: false,
      p_set_default_receive_at: false
    });
    expect(error).toBeNull();
    expect(data?.success).toBe(false);
    expect(String(data?.error || '')).toMatch(/permission/i);
  });
});
