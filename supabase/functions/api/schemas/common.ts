// ============================================================================
// COMMON ZOD SCHEMAS
// ============================================================================

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

// UUID v4 validation
export const uuidSchema = z.string().uuid({
  message: 'Must be a valid UUID',
});

// ISO 8601 datetime
export const datetimeSchema = z.string().datetime({
  message: 'Must be a valid ISO 8601 datetime',
});

// Non-empty string with length limits
export const nonEmptyString = (maxLength: number) =>
  z.string()
    .min(1, 'Cannot be empty')
    .max(maxLength, `Cannot exceed ${maxLength} characters`);

// Positive integer
export const positiveInt = z.number().int().positive({
  message: 'Must be a positive integer',
});

// Non-negative integer
export const nonNegativeInt = z.number().int().min(0, {
  message: 'Must be a non-negative integer',
});

// Currency amount (2 decimal places max)
export const currencyAmount = z.number()
  .min(0, 'Must be non-negative')
  .refine(
    (val) => Number.isFinite(val) && Math.round(val * 100) === val * 100,
    'Cannot have more than 2 decimal places'
  );
