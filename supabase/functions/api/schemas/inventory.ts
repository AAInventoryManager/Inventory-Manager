// ============================================================================
// INVENTORY ZOD SCHEMAS
// ============================================================================

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { nonEmptyString, nonNegativeInt, currencyAmount } from './common.ts';

// SKU pattern: alphanumeric with dashes and underscores
const skuPattern = /^[A-Za-z0-9_-]+$/;

// Base inventory fields
const inventoryFieldsBase = {
  name: nonEmptyString(255),
  sku: z.string()
    .min(1, 'SKU is required')
    .max(50, 'SKU cannot exceed 50 characters')
    .regex(skuPattern, 'SKU must contain only letters, numbers, dashes, and underscores'),
  description: z.string().max(2000).nullish(),
  quantity: nonNegativeInt,
  unit: z.string().max(50).default('each'),
  category: z.string().max(100).nullish(),
  location: z.string().max(200).nullish(),
  reorder_point: nonNegativeInt.nullish(),
  reorder_quantity: z.number().int().positive().nullish(),
  unit_cost: currencyAmount.nullish(),
  supplier: z.string().max(200).nullish(),
  barcode: z.string().max(50).nullish(),
  notes: z.string().max(5000).nullish(),
  custom_fields: z.record(z.unknown()).nullish(),
};

/**
 * Schema for creating a new inventory item
 */
export const inventoryCreateSchema = z.object({
  name: inventoryFieldsBase.name,
  sku: inventoryFieldsBase.sku,
  quantity: inventoryFieldsBase.quantity,
  description: inventoryFieldsBase.description,
  unit: inventoryFieldsBase.unit,
  category: inventoryFieldsBase.category,
  location: inventoryFieldsBase.location,
  reorder_point: inventoryFieldsBase.reorder_point,
  reorder_quantity: inventoryFieldsBase.reorder_quantity,
  unit_cost: inventoryFieldsBase.unit_cost,
  supplier: inventoryFieldsBase.supplier,
  barcode: inventoryFieldsBase.barcode,
  notes: inventoryFieldsBase.notes,
  custom_fields: inventoryFieldsBase.custom_fields,
}).refine(
  (data) => {
    if (data.reorder_quantity !== null && data.reorder_quantity !== undefined) {
      return data.reorder_point !== null && data.reorder_point !== undefined;
    }
    return true;
  },
  {
    message: 'reorder_point is required when reorder_quantity is specified',
    path: ['reorder_point'],
  }
);

/**
 * Schema for updating an existing inventory item
 */
export const inventoryUpdateSchema = z.object({
  name: inventoryFieldsBase.name.optional(),
  sku: inventoryFieldsBase.sku.optional(),
  description: inventoryFieldsBase.description,
  quantity: inventoryFieldsBase.quantity.optional(),
  unit: inventoryFieldsBase.unit.optional(),
  category: inventoryFieldsBase.category,
  location: inventoryFieldsBase.location,
  reorder_point: inventoryFieldsBase.reorder_point,
  reorder_quantity: inventoryFieldsBase.reorder_quantity,
  unit_cost: inventoryFieldsBase.unit_cost,
  supplier: inventoryFieldsBase.supplier,
  barcode: inventoryFieldsBase.barcode,
  notes: inventoryFieldsBase.notes,
  custom_fields: inventoryFieldsBase.custom_fields,
  is_archived: z.boolean().optional(),
}).refine(
  (data) => Object.values(data).some((v) => v !== undefined),
  { message: 'At least one field must be provided for update' }
);

/**
 * Schema for inventory quantity adjustment
 */
export const inventoryAdjustmentSchema = z.object({
  type: z.enum(['add', 'subtract', 'set'], {
    errorMap: () => ({ message: "Type must be 'add', 'subtract', or 'set'" }),
  }),
  amount: nonNegativeInt,
  reason: z.enum([
    'received_shipment',
    'returned_item',
    'damaged_goods',
    'theft_loss',
    'expired',
    'physical_count',
    'transfer_in',
    'transfer_out',
    'production_use',
    'other',
  ]),
  notes: z.string().max(1000).nullish(),
  reference: z.string().max(100).nullish(),
});

/**
 * Schema for bulk create
 */
export const inventoryBulkCreateSchema = z.object({
  items: z.array(inventoryCreateSchema)
    .min(1, 'At least one item is required')
    .max(100, 'Cannot create more than 100 items at once'),
});

// Export types
export type InventoryCreate = z.infer<typeof inventoryCreateSchema>;
export type InventoryUpdate = z.infer<typeof inventoryUpdateSchema>;
export type InventoryAdjustment = z.infer<typeof inventoryAdjustmentSchema>;
export type InventoryBulkCreate = z.infer<typeof inventoryBulkCreateSchema>;
