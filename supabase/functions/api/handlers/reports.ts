// ============================================================================
// REPORTS HANDLERS
// ============================================================================

import type { AuthContext } from '../middleware/auth.ts';
import { lowStockQuerySchema } from '../schemas/pagination.ts';
import { validateQuery } from '../utils/validate.ts';
import { AuthorizationError } from '../utils/errors.ts';
import { jsonResponse } from '../utils/responses.ts';

// ============================================================================
// GET /v1/inventory/low-stock - Get low stock items
// ============================================================================

export async function handleLowStock(
  request: Request,
  auth: AuthContext | null,
  _params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();
  
  const url = new URL(request.url);
  const query = validateQuery(lowStockQuerySchema, url);
  
  // Use the database function for low stock query
  const { data, error } = await auth.supabase.rpc('get_low_stock_items', {
    p_category: query.category || null,
    p_location: query.location || null,
    p_include_zero: query.include_zero,
    p_urgency: query.urgency,
    p_limit: query.limit,
    p_offset: query.offset,
  });
  
  if (error) {
    throw new Error(`Database error: ${error.message}`);
  }
  
  const items = data || [];
  
  // Calculate summary
  const criticalCount = items.filter((item: { urgency: string }) => 
    item.urgency === 'critical'
  ).length;
  
  const warningCount = items.filter((item: { urgency: string }) => 
    item.urgency === 'warning'
  ).length;
  
  const totalDeficitValue = items.reduce((sum: number, item: { deficit: number; unit_cost: number | null }) => {
    if (item.unit_cost) {
      return sum + (item.deficit * item.unit_cost);
    }
    return sum;
  }, 0);
  
  // Use items length for pagination since RPC does not return counts
  const total = items.length < query.limit ? 
    query.offset + items.length : 
    query.offset + query.limit + 1; // Indicate there might be more
  
  return jsonResponse({
    data: items,
    meta: {
      total,
      limit: query.limit,
      offset: query.offset,
      has_more: items.length === query.limit,
      summary: {
        critical_count: criticalCount,
        warning_count: warningCount,
        total_deficit_value: Math.round(totalDeficitValue * 100) / 100,
      },
    },
  });
}
