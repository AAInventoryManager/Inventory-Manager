// ============================================================================
// PAGINATION AND QUERY SCHEMAS
// ============================================================================

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// Sortable fields for inventory
const sortableFields = [
  'name',
  'sku',
  'quantity',
  'category',
  'location',
  'created_at',
  'updated_at',
  'unit_cost',
] as const;

/**
 * Sort parameter parser
 * Format: "field:direction,field:direction"
 */
const sortSchema = z.string().optional().transform((val, ctx) => {
  if (!val) return [{ field: 'name' as const, direction: 'asc' as const }];

  const sorts = val.split(',').map((s) => {
    const [field, direction = 'asc'] = s.trim().split(':');
    
    if (!sortableFields.includes(field as typeof sortableFields[number])) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Invalid sort field '${field}'. Valid fields: ${sortableFields.join(', ')}`,
      });
      return null;
    }
    
    if (!['asc', 'desc'].includes(direction)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Invalid sort direction '${direction}'. Use 'asc' or 'desc'.`,
      });
      return null;
    }
    
    return { field: field as typeof sortableFields[number], direction: direction as 'asc' | 'desc' };
  });

  return sorts.filter((s): s is NonNullable<typeof s> => s !== null);
});

/**
 * Query parameters for listing inventory
 */
export const inventoryQuerySchema = z.object({
  // Text search
  search: z.string().max(100).optional(),
  
  // Filters
  category: z.string().max(100).optional(),
  location: z.string().max(200).optional(),
  min_quantity: z.coerce.number().int().min(0).optional(),
  max_quantity: z.coerce.number().int().min(0).optional(),
  created_after: z.string().datetime().optional(),
  created_before: z.string().datetime().optional(),
  updated_after: z.string().datetime().optional(),
  include_archived: z.string().optional().transform((val) => val === 'true'),
  
  // Sorting
  sort: sortSchema,
  
  // Pagination
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).default(0),
}).refine(
  (data) => {
    if (data.min_quantity !== undefined && data.max_quantity !== undefined) {
      return data.min_quantity <= data.max_quantity;
    }
    return true;
  },
  { message: 'min_quantity cannot be greater than max_quantity' }
);

/**
 * Query parameters for low-stock report
 */
export const lowStockQuerySchema = z.object({
  category: z.string().max(100).optional(),
  location: z.string().max(200).optional(),
  include_zero: z.string().optional().transform((val) => val !== 'false'),
  urgency: z.enum(['critical', 'warning', 'all']).default('all'),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

export type InventoryQuery = z.infer<typeof inventoryQuerySchema>;
export type LowStockQuery = z.infer<typeof lowStockQuerySchema>;
export type SortField = typeof sortableFields[number];
