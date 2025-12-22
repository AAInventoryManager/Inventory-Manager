// ============================================================================
// INVENTORY HANDLERS
// ============================================================================

import type { AuthContext } from '../middleware/auth.ts';
import { 
  inventoryCreateSchema, 
  inventoryUpdateSchema,
  inventoryAdjustmentSchema,
  inventoryBulkCreateSchema,
} from '../schemas/inventory.ts';
import { inventoryQuerySchema } from '../schemas/pagination.ts';
import { validateBody, validateQuery, isValidUUID } from '../utils/validate.ts';
import { 
  NotFoundError, 
  ConflictError, 
  ValidationError,
  AuthorizationError,
} from '../utils/errors.ts';
import { 
  jsonResponse, 
  paginatedResponse, 
  createdResponse, 
  noContentResponse,
} from '../utils/responses.ts';

// ============================================================================
// GET /v1/inventory - List inventory items
// ============================================================================

export async function handleListInventory(
  request: Request,
  auth: AuthContext | null,
  _params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const url = new URL(request.url);
  const query = validateQuery(inventoryQuerySchema, url);
  
  // Build Supabase query
  let dbQuery = auth.supabase
    .from('inventory')
    .select('*', { count: 'exact' });
  
  // Apply filters
  if (!query.include_archived) {
    dbQuery = dbQuery.eq('is_archived', false);
  }
  
  if (query.category) {
    dbQuery = dbQuery.ilike('category', query.category);
  }
  
  if (query.location) {
    dbQuery = dbQuery.ilike('location', `%${query.location}%`);
  }
  
  if (query.min_quantity !== undefined) {
    dbQuery = dbQuery.gte('quantity', query.min_quantity);
  }
  
  if (query.max_quantity !== undefined) {
    dbQuery = dbQuery.lte('quantity', query.max_quantity);
  }
  
  if (query.created_after) {
    dbQuery = dbQuery.gte('created_at', query.created_after);
  }
  
  if (query.created_before) {
    dbQuery = dbQuery.lte('created_at', query.created_before);
  }
  
  if (query.updated_after) {
    dbQuery = dbQuery.gte('updated_at', query.updated_after);
  }
  
  // Full-text search
  if (query.search) {
    // Search across name, sku, description
    dbQuery = dbQuery.or(
      `name.ilike.%${query.search}%,sku.ilike.%${query.search}%,description.ilike.%${query.search}%,barcode.eq.${query.search}`
    );
  }
  
  // Apply sorting
  if (query.sort && query.sort.length > 0) {
    for (const sort of query.sort) {
      dbQuery = dbQuery.order(sort.field, { ascending: sort.direction === 'asc' });
    }
  }
  
  // Apply pagination
  dbQuery = dbQuery.range(query.offset, query.offset + query.limit - 1);
  
  const { data, error, count } = await dbQuery;
  
  if (error) {
    throw new Error(`Database error: ${error.message}`);
  }
  
  return paginatedResponse(data || [], {
    total: count || 0,
    limit: query.limit,
    offset: query.offset,
  });
}

// ============================================================================
// GET /v1/inventory/:id - Get single inventory item
// ============================================================================

export async function handleGetInventory(
  _request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const { id } = params;
  
  if (!isValidUUID(id)) {
    throw new ValidationError('Invalid inventory ID', [
      { field: 'id', message: 'Must be a valid UUID', code: 'invalid_format' }
    ]);
  }
  
  const { data, error } = await auth.supabase
    .from('inventory')
    .select('*')
    .eq('id', id)
    .single();
  
  if (error || !data) {
    throw new NotFoundError('Inventory item');
  }
  
  return jsonResponse({ data });
}

// ============================================================================
// POST /v1/inventory - Create inventory item
// ============================================================================

export async function handleCreateInventory(
  request: Request,
  auth: AuthContext | null,
  _params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const body = await validateBody(inventoryCreateSchema, request);
  
  // Add audit fields
  const insertData = {
    ...body,
    company_id: auth.user.company_id,
    created_by: auth.user.id,
    updated_by: auth.user.id,
  };
  
  const { data, error } = await auth.supabase
    .from('inventory')
    .insert(insertData)
    .select()
    .single();
  
  if (error) {
    // Check for unique constraint violation
    if (error.code === '23505' && error.message.includes('sku')) {
      throw new ConflictError(`An item with SKU '${body.sku}' already exists`, 'sku');
    }
    throw new Error(`Database error: ${error.message}`);
  }
  
  return createdResponse(data, `/v1/inventory/${data.id}`);
}

// ============================================================================
// PATCH /v1/inventory/:id - Update inventory item
// ============================================================================

export async function handleUpdateInventory(
  request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const { id } = params;
  
  if (!isValidUUID(id)) {
    throw new ValidationError('Invalid inventory ID', [
      { field: 'id', message: 'Must be a valid UUID', code: 'invalid_format' }
    ]);
  }
  
  const body = await validateBody(inventoryUpdateSchema, request);
  
  // Add audit field
  const updateData = {
    ...body,
    updated_by: auth.user.id,
  };
  
  // Handle archiving
  if (body.is_archived === true) {
    Object.assign(updateData, {
      archived_at: new Date().toISOString(),
      archived_by: auth.user.id,
    });
  } else if (body.is_archived === false) {
    Object.assign(updateData, {
      archived_at: null,
      archived_by: null,
    });
  }
  
  const { data, error } = await auth.supabase
    .from('inventory')
    .update(updateData)
    .eq('id', id)
    .select()
    .single();
  
  if (error) {
    if (error.code === 'PGRST116') {
      throw new NotFoundError('Inventory item');
    }
    if (error.code === '23505' && error.message.includes('sku')) {
      throw new ConflictError(`An item with SKU '${body.sku}' already exists`, 'sku');
    }
    throw new Error(`Database error: ${error.message}`);
  }
  
  if (!data) {
    throw new NotFoundError('Inventory item');
  }
  
  return jsonResponse({ data });
}

// ============================================================================
// DELETE /v1/inventory/:id - Delete inventory item
// ============================================================================

export async function handleDeleteInventory(
  request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const { id } = params;
  
  if (!isValidUUID(id)) {
    throw new ValidationError('Invalid inventory ID', [
      { field: 'id', message: 'Must be a valid UUID', code: 'invalid_format' }
    ]);
  }
  
  // Check for permanent delete flag
  const url = new URL(request.url);
  const permanent = url.searchParams.get('permanent') === 'true';
  
  if (permanent) {
    // Hard delete
    const { error } = await auth.supabase
      .from('inventory')
      .delete()
      .eq('id', id);
    
    if (error) {
      if (error.code === 'PGRST116') {
        // Item doesn't exist - idempotent success
        return noContentResponse();
      }
      throw new Error(`Database error: ${error.message}`);
    }
  } else {
    // Soft delete (archive)
    const { error } = await auth.supabase
      .from('inventory')
      .update({
        is_archived: true,
        archived_at: new Date().toISOString(),
        archived_by: auth.user.id,
        updated_by: auth.user.id,
      })
      .eq('id', id);
    
    if (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
  
  return noContentResponse();
}

// ============================================================================
// POST /v1/inventory/bulk - Bulk create inventory items
// ============================================================================

export async function handleBulkCreateInventory(
  request: Request,
  auth: AuthContext | null,
  _params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const body = await validateBody(inventoryBulkCreateSchema, request);
  
  // Add company_id and audit fields to each item
  const insertData = body.items.map((item) => ({
    ...item,
    company_id: auth.user.company_id,
    created_by: auth.user.id,
    updated_by: auth.user.id,
  }));
  
  const { data, error } = await auth.supabase
    .from('inventory')
    .insert(insertData)
    .select();
  
  if (error) {
    // Check for unique constraint violation
    if (error.code === '23505' && error.message.includes('sku')) {
      throw new ConflictError(
        'One or more items have duplicate SKUs',
        'items.sku'
      );
    }
    throw new Error(`Database error: ${error.message}`);
  }
  
  return jsonResponse({
    data,
    meta: {
      created_count: data?.length || 0,
    },
  }, 201);
}

// ============================================================================
// POST /v1/inventory/:id/adjust - Adjust inventory quantity
// ============================================================================

export async function handleAdjustInventory(
  request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const { id } = params;
  
  if (!isValidUUID(id)) {
    throw new ValidationError('Invalid inventory ID', [
      { field: 'id', message: 'Must be a valid UUID', code: 'invalid_format' }
    ]);
  }
  
  const body = await validateBody(inventoryAdjustmentSchema, request);
  
  // Use the database function for atomic adjustment
  const { data, error } = await auth.supabase.rpc('adjust_inventory_quantity', {
    p_inventory_id: id,
    p_adjustment_type: body.type,
    p_amount: body.amount,
    p_reason: body.reason,
    p_notes: body.notes || null,
    p_reference: body.reference || null,
  });
  
  if (error) {
    if (error.message.includes('not found')) {
      throw new NotFoundError('Inventory item');
    }
    if (error.message.includes('negative quantity')) {
      throw new ConflictError('Adjustment would result in negative quantity');
    }
    if (error.message.includes('Access denied')) {
      throw new NotFoundError('Inventory item'); // Don't reveal access denied
    }
    throw new Error(`Database error: ${error.message}`);
  }
  
  const result = data?.[0];
  
  // Fetch updated item
  const { data: item } = await auth.supabase
    .from('inventory')
    .select('*')
    .eq('id', id)
    .single();
  
  return jsonResponse({
    data: item,
    adjustment: {
      id: result?.adjustment_id,
      previous_quantity: result?.previous_quantity,
      new_quantity: result?.new_quantity,
      change: result?.new_quantity - result?.previous_quantity,
      reason: body.reason,
      recorded_at: new Date().toISOString(),
    },
  });
}
