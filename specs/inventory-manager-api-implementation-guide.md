# Inventory Manager API — Implementation Guide

This document accompanies the OpenAPI specification (`inventory-manager-api-spec.yaml`) and provides implementation details for building the API using Supabase Edge Functions.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Project Structure](#2-project-structure)
3. [CORS Configuration](#3-cors-configuration)
4. [Input Validation with Zod](#4-input-validation-with-zod)
5. [Authentication & Authorization](#5-authentication--authorization)
6. [Rate Limiting](#6-rate-limiting)
7. [Idempotency Implementation](#7-idempotency-implementation)
8. [Structured Logging](#8-structured-logging)
9. [Error Handling](#9-error-handling)
10. [Testing Strategy](#10-testing-strategy)
11. [Deployment](#11-deployment)
12. [Security Considerations](#12-security-considerations)

---

## 1. Architecture Overview

### Request Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT REQUEST                                   │
│                    Authorization: Bearer <jwt_token>                         │
└─────────────────────────────────┬────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SUPABASE EDGE FUNCTION                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │    CORS     │→ │   Auth      │→ │   Rate      │→ │   Input             │  │
│  │   Handler   │  │  Validator  │  │   Limiter   │  │   Validation (Zod)  │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                               │               │
│                                                               ▼               │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │                        ROUTE HANDLER                                     │ │
│  │   • Extract parameters                                                   │ │
│  │   • Build Supabase query                                                │ │
│  │   • Execute with RLS-scoped client                                      │ │
│  │   • Format response                                                      │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────┬────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              POSTGRESQL + RLS                                 │
│                                                                              │
│   SELECT * FROM inventory WHERE company_id = auth.jwt() -> 'company_id'     │
│   ─────────────────────────────────────────────────────────────────────     │
│   RLS Policy automatically filters to user's company — cannot be bypassed   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why This Architecture is Safe

1. **RLS is the single source of truth** — Even if application code has bugs, the database enforces data isolation
2. **No service-role keys in API** — We use the user's JWT to create a scoped Supabase client
3. **Additive design** — Existing frontend continues using Supabase client directly; API is an additional access path
4. **Validation before execution** — Zod schemas catch malformed input before it reaches the database

---

## 2. Project Structure

```
supabase/
├── functions/
│   └── api/
│       ├── index.ts              # Main router / entry point
│       ├── deps.ts               # Centralized dependency imports
│       │
│       ├── middleware/
│       │   ├── cors.ts           # CORS handling
│       │   ├── auth.ts           # JWT validation & client creation
│       │   ├── rate-limit.ts     # Rate limiting logic
│       │   └── request-id.ts     # Request ID generation
│       │
│       ├── handlers/
│       │   ├── health.ts         # GET /health
│       │   ├── inventory.ts      # CRUD for /v1/inventory
│       │   └── reports.ts        # GET /v1/inventory/low-stock
│       │
│       ├── schemas/
│       │   ├── inventory.ts      # Zod schemas for inventory
│       │   ├── pagination.ts     # Zod schemas for query params
│       │   └── common.ts         # Shared schemas (UUID, etc.)
│       │
│       ├── utils/
│       │   ├── responses.ts      # Standardized response helpers
│       │   ├── errors.ts         # Error classes and codes
│       │   ├── logger.ts         # Structured logging
│       │   └── idempotency.ts    # Idempotency key handling
│       │
│       └── types/
│           └── index.ts          # TypeScript type definitions
│
├── migrations/
│   └── 20240115_add_idempotency_table.sql
│
└── config.toml
```

---

## 3. CORS Configuration

### Why CORS Matters

CORS (Cross-Origin Resource Sharing) controls which domains can make requests to your API from a browser. Without proper CORS headers:
- Your own frontend on a different subdomain won't work
- Third-party integrations from browsers will fail
- Preflight OPTIONS requests will be rejected

### Implementation

```typescript
// supabase/functions/api/middleware/cors.ts

/**
 * CORS Configuration
 * 
 * Handles Cross-Origin Resource Sharing headers for browser-based clients.
 * Supabase Edge Functions don't include CORS headers by default.
 */

// Define allowed origins (configure per environment)
const ALLOWED_ORIGINS = [
  'http://localhost:3000',                    // Local development
  'http://localhost:5173',                    // Vite dev server
  'https://inventory-manager.example.com',   // Production frontend
  'https://staging.inventory-manager.example.com', // Staging
];

// For development, you might allow all origins (NOT for production)
const ALLOW_ALL_ORIGINS = Deno.env.get('ENVIRONMENT') === 'development';

export interface CorsConfig {
  allowedOrigins: string[];
  allowedMethods: string[];
  allowedHeaders: string[];
  exposedHeaders: string[];
  maxAge: number;
  credentials: boolean;
}

const defaultConfig: CorsConfig = {
  allowedOrigins: ALLOWED_ORIGINS,
  allowedMethods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: [
    'Authorization',
    'Content-Type',
    'Idempotency-Key',
    'X-Request-Id',
  ],
  exposedHeaders: [
    'X-RateLimit-Limit',
    'X-RateLimit-Remaining',
    'X-RateLimit-Reset',
    'X-Request-Id',
    'Location',
  ],
  maxAge: 86400, // 24 hours — browsers cache preflight responses
  credentials: true,
};

/**
 * Get CORS headers for a request
 */
export function getCorsHeaders(
  request: Request,
  config: CorsConfig = defaultConfig
): Headers {
  const headers = new Headers();
  const origin = request.headers.get('Origin');

  // Check if origin is allowed
  const isAllowed = ALLOW_ALL_ORIGINS || 
    (origin && config.allowedOrigins.includes(origin));

  if (isAllowed && origin) {
    // Set specific origin (not '*') to allow credentials
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
  }

  // Always set these for preflight caching
  headers.set('Access-Control-Allow-Methods', config.allowedMethods.join(', '));
  headers.set('Access-Control-Allow-Headers', config.allowedHeaders.join(', '));
  headers.set('Access-Control-Expose-Headers', config.exposedHeaders.join(', '));
  headers.set('Access-Control-Max-Age', config.maxAge.toString());

  return headers;
}

/**
 * Handle CORS preflight (OPTIONS) requests
 */
export function handlePreflight(request: Request): Response {
  const corsHeaders = getCorsHeaders(request);
  
  return new Response(null, {
    status: 204, // No Content
    headers: corsHeaders,
  });
}

/**
 * Add CORS headers to an existing response
 */
export function withCors(request: Request, response: Response): Response {
  const corsHeaders = getCorsHeaders(request);
  
  // Clone response and add CORS headers
  const newHeaders = new Headers(response.headers);
  corsHeaders.forEach((value, key) => {
    newHeaders.set(key, value);
  });

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

/**
 * CORS middleware wrapper
 */
export function corsMiddleware(
  handler: (request: Request) => Promise<Response>
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    // Handle preflight requests
    if (request.method === 'OPTIONS') {
      return handlePreflight(request);
    }

    // Process request and add CORS headers to response
    const response = await handler(request);
    return withCors(request, response);
  };
}
```

---

## 4. Input Validation with Zod

### Why Zod?

- **Type-safe**: Generates TypeScript types from schemas
- **Runtime validation**: Catches bad input before it hits the database
- **Descriptive errors**: Clear, field-level error messages for clients
- **Composable**: Build complex schemas from simple primitives

### Schema Definitions

```typescript
// supabase/functions/api/schemas/common.ts

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

/**
 * Common reusable schemas
 */

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
  z.string().min(1, 'Cannot be empty').max(maxLength, `Cannot exceed ${maxLength} characters`);

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
  .multipleOf(0.01, 'Cannot have more than 2 decimal places');
```

```typescript
// supabase/functions/api/schemas/inventory.ts

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { uuidSchema, nonEmptyString, nonNegativeInt, currencyAmount } from './common.ts';

/**
 * SKU pattern: alphanumeric with dashes and underscores
 */
const skuPattern = /^[A-Za-z0-9_-]+$/;

/**
 * Base inventory item fields (shared between create/update)
 */
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
 * Required: name, sku, quantity
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
  // Business rule: if reorder_quantity is set, reorder_point must also be set
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
 * All fields optional, but at least one required
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
  // Ensure at least one field is being updated
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

// Export inferred TypeScript types
export type InventoryCreate = z.infer<typeof inventoryCreateSchema>;
export type InventoryUpdate = z.infer<typeof inventoryUpdateSchema>;
export type InventoryAdjustment = z.infer<typeof inventoryAdjustmentSchema>;
export type InventoryBulkCreate = z.infer<typeof inventoryBulkCreateSchema>;
```

```typescript
// supabase/functions/api/schemas/pagination.ts

import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

/**
 * Sortable fields for inventory
 */
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
 * Example: "quantity:desc,name:asc"
 */
const sortSchema = z.string().transform((val, ctx) => {
  if (!val) return [{ field: 'name', direction: 'asc' as const }];

  const sorts = val.split(',').map((s) => {
    const [field, direction = 'asc'] = s.trim().split(':');
    
    if (!sortableFields.includes(field as any)) {
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
    
    return { field, direction: direction as 'asc' | 'desc' };
  });

  return sorts.filter(Boolean);
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
  include_archived: z.coerce.boolean().default(false),
  
  // Sorting
  sort: sortSchema.default('name:asc'),
  
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
  include_zero: z.coerce.boolean().default(true),
  urgency: z.enum(['critical', 'warning', 'all']).default('all'),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

export type InventoryQuery = z.infer<typeof inventoryQuerySchema>;
export type LowStockQuery = z.infer<typeof lowStockQuerySchema>;
```

### Validation Helper

```typescript
// supabase/functions/api/utils/validate.ts

import { z, ZodError, ZodSchema } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { ValidationError } from './errors.ts';

/**
 * Validate data against a Zod schema
 * Throws ValidationError with formatted errors if validation fails
 */
export function validate<T>(schema: ZodSchema<T>, data: unknown): T {
  try {
    return schema.parse(data);
  } catch (error) {
    if (error instanceof ZodError) {
      const formattedErrors = error.errors.map((err) => ({
        field: err.path.join('.'),
        message: err.message,
        code: zodIssueCodeToErrorCode(err.code),
      }));
      
      throw new ValidationError('Request validation failed', formattedErrors);
    }
    throw error;
  }
}

/**
 * Validate query parameters from URL
 */
export function validateQuery<T>(
  schema: ZodSchema<T>,
  url: URL
): T {
  const params: Record<string, string> = {};
  url.searchParams.forEach((value, key) => {
    params[key] = value;
  });
  return validate(schema, params);
}

/**
 * Validate JSON request body
 */
export async function validateBody<T>(
  schema: ZodSchema<T>,
  request: Request
): Promise<T> {
  let body: unknown;
  
  try {
    body = await request.json();
  } catch {
    throw new ValidationError('Invalid JSON in request body', [
      { field: 'body', message: 'Request body must be valid JSON', code: 'invalid_format' }
    ]);
  }
  
  return validate(schema, body);
}

/**
 * Map Zod issue codes to our error codes
 */
function zodIssueCodeToErrorCode(code: z.ZodIssueCode): string {
  const mapping: Record<string, string> = {
    invalid_type: 'type_error',
    invalid_string: 'invalid_format',
    too_small: 'min_length',
    too_big: 'max_length',
    invalid_enum_value: 'invalid_format',
    unrecognized_keys: 'invalid_format',
    custom: 'validation_error',
  };
  return mapping[code] || 'validation_error';
}
```

---

## 5. Authentication & Authorization

### JWT Validation

```typescript
// supabase/functions/api/middleware/auth.ts

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { AuthenticationError } from '../utils/errors.ts';

/**
 * Authenticated request context
 */
export interface AuthContext {
  user: {
    id: string;
    email: string;
    company_id: string;
  };
  supabase: SupabaseClient;
}

/**
 * Extract and validate JWT from Authorization header
 * Returns an authenticated Supabase client scoped to the user
 */
export async function authenticate(request: Request): Promise<AuthContext> {
  const authHeader = request.headers.get('Authorization');
  
  if (!authHeader) {
    throw new AuthenticationError('Missing Authorization header');
  }
  
  if (!authHeader.startsWith('Bearer ')) {
    throw new AuthenticationError('Authorization header must use Bearer scheme');
  }
  
  const token = authHeader.slice(7); // Remove 'Bearer ' prefix
  
  if (!token) {
    throw new AuthenticationError('Missing JWT token');
  }

  // Create Supabase client with the user's JWT
  // This client will have RLS applied based on the token's claims
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
  
  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error('Missing Supabase configuration');
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    },
  });

  // Verify the token by attempting to get the user
  const { data: { user }, error } = await supabase.auth.getUser(token);
  
  if (error || !user) {
    throw new AuthenticationError('Invalid or expired JWT token');
  }

  // Extract company_id from app_metadata
  const companyId = user.app_metadata?.company_id;
  
  if (!companyId) {
    throw new AuthenticationError('User is not associated with a company');
  }

  return {
    user: {
      id: user.id,
      email: user.email!,
      company_id: companyId,
    },
    supabase,
  };
}

/**
 * Authentication middleware wrapper
 */
export function withAuth<T>(
  handler: (request: Request, auth: AuthContext) => Promise<T>
): (request: Request) => Promise<T> {
  return async (request: Request) => {
    const auth = await authenticate(request);
    return handler(request, auth);
  };
}
```

### Why We Don't Use Service-Role Keys

**Service-role keys bypass RLS.** If you use them in a public API:

1. **Any bug in your code becomes a data breach** — RLS won't save you
2. **All authorization logic must be in application code** — error-prone and duplicated
3. **Cross-tenant access is one typo away** — `WHERE company_id = $1` forgotten once = disaster

**With user JWTs:**
1. RLS is the last line of defense even if your code has bugs
2. Authorization is declarative, in one place (RLS policies)
3. Multi-tenancy is guaranteed by the database

---

## 6. Rate Limiting

```typescript
// supabase/functions/api/middleware/rate-limit.ts

import { RateLimitError } from '../utils/errors.ts';

/**
 * Rate limit configuration per tier
 */
interface RateLimitConfig {
  windowMs: number;     // Time window in milliseconds
  maxRequests: number;  // Max requests per window
  burstLimit: number;   // Allow brief bursts above max
}

const RATE_LIMITS: Record<string, RateLimitConfig> = {
  standard: { windowMs: 60000, maxRequests: 100, burstLimit: 150 },
  premium: { windowMs: 60000, maxRequests: 500, burstLimit: 750 },
  enterprise: { windowMs: 60000, maxRequests: 2000, burstLimit: 3000 },
};

/**
 * In-memory rate limit store
 * NOTE: For production with multiple Edge Function instances,
 * use Supabase Database or Redis for distributed rate limiting
 */
const rateLimitStore = new Map<string, { count: number; resetAt: number }>();

/**
 * Check and update rate limit for a user
 */
export async function checkRateLimit(
  userId: string,
  tier: string = 'standard'
): Promise<{ remaining: number; limit: number; resetAt: number }> {
  const config = RATE_LIMITS[tier] || RATE_LIMITS.standard;
  const key = `${userId}:${tier}`;
  const now = Date.now();
  
  let entry = rateLimitStore.get(key);
  
  // Reset if window has passed
  if (!entry || now >= entry.resetAt) {
    entry = {
      count: 0,
      resetAt: now + config.windowMs,
    };
  }
  
  entry.count++;
  rateLimitStore.set(key, entry);
  
  const remaining = Math.max(0, config.maxRequests - entry.count);
  
  if (entry.count > config.burstLimit) {
    const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
    throw new RateLimitError(retryAfter, config.maxRequests, entry.resetAt);
  }
  
  return {
    remaining,
    limit: config.maxRequests,
    resetAt: Math.floor(entry.resetAt / 1000), // Unix timestamp
  };
}

/**
 * Get rate limit headers for response
 */
export function getRateLimitHeaders(
  rateLimit: { remaining: number; limit: number; resetAt: number }
): Headers {
  const headers = new Headers();
  headers.set('X-RateLimit-Limit', rateLimit.limit.toString());
  headers.set('X-RateLimit-Remaining', rateLimit.remaining.toString());
  headers.set('X-RateLimit-Reset', rateLimit.resetAt.toString());
  return headers;
}
```

---

## 7. Idempotency Implementation

```typescript
// supabase/functions/api/utils/idempotency.ts

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

/**
 * Idempotency ensures that retrying a request produces the same result
 * without duplicating side effects (like creating duplicate records).
 */

interface IdempotencyRecord {
  key: string;
  user_id: string;
  response_status: number;
  response_body: string;
  created_at: string;
}

const IDEMPOTENCY_TTL_HOURS = 24;

/**
 * Check if an idempotency key has been used before
 * Returns the cached response if found, null otherwise
 */
export async function checkIdempotencyKey(
  supabase: SupabaseClient,
  key: string,
  userId: string
): Promise<Response | null> {
  const { data, error } = await supabase
    .from('idempotency_keys')
    .select('*')
    .eq('key', key)
    .eq('user_id', userId)
    .single();
  
  if (error || !data) {
    return null;
  }
  
  // Check if key has expired
  const createdAt = new Date(data.created_at);
  const expiresAt = new Date(createdAt.getTime() + IDEMPOTENCY_TTL_HOURS * 60 * 60 * 1000);
  
  if (new Date() > expiresAt) {
    // Key expired, delete it and return null
    await supabase
      .from('idempotency_keys')
      .delete()
      .eq('key', key)
      .eq('user_id', userId);
    return null;
  }
  
  // Return cached response
  return new Response(data.response_body, {
    status: data.response_status,
    headers: {
      'Content-Type': 'application/json',
      'X-Idempotency-Replayed': 'true',
    },
  });
}

/**
 * Store an idempotency key with its response
 */
export async function storeIdempotencyKey(
  supabase: SupabaseClient,
  key: string,
  userId: string,
  response: Response
): Promise<void> {
  const body = await response.clone().text();
  
  await supabase
    .from('idempotency_keys')
    .upsert({
      key,
      user_id: userId,
      response_status: response.status,
      response_body: body,
      created_at: new Date().toISOString(),
    });
}

/**
 * Middleware for idempotent endpoints
 */
export async function withIdempotency(
  request: Request,
  supabase: SupabaseClient,
  userId: string,
  handler: () => Promise<Response>
): Promise<Response> {
  const idempotencyKey = request.headers.get('Idempotency-Key');
  
  if (!idempotencyKey) {
    // No idempotency key provided, execute normally
    return handler();
  }
  
  // Check for existing response
  const cachedResponse = await checkIdempotencyKey(supabase, idempotencyKey, userId);
  if (cachedResponse) {
    return cachedResponse;
  }
  
  // Execute handler and cache response
  const response = await handler();
  
  // Only cache successful responses (2xx)
  if (response.status >= 200 && response.status < 300) {
    await storeIdempotencyKey(supabase, idempotencyKey, userId, response);
  }
  
  return response;
}
```

### Database Migration for Idempotency

```sql
-- supabase/migrations/20240115_add_idempotency_table.sql

CREATE TABLE IF NOT EXISTS idempotency_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  response_status INTEGER NOT NULL,
  response_body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  CONSTRAINT unique_key_per_user UNIQUE (key, user_id)
);

-- Index for fast lookups
CREATE INDEX idx_idempotency_keys_lookup 
ON idempotency_keys (key, user_id);

-- Index for TTL cleanup
CREATE INDEX idx_idempotency_keys_created 
ON idempotency_keys (created_at);

-- RLS: Users can only see/manage their own idempotency keys
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own idempotency keys"
ON idempotency_keys
FOR ALL
USING (user_id = auth.uid());

-- Scheduled cleanup of expired keys (run via pg_cron or external scheduler)
-- DELETE FROM idempotency_keys WHERE created_at < NOW() - INTERVAL '24 hours';
```

---

## 8. Structured Logging

```typescript
// supabase/functions/api/utils/logger.ts

/**
 * Structured JSON logging for observability
 * 
 * Log levels:
 * - debug: Development troubleshooting
 * - info: Normal operations (requests, responses)
 * - warn: Unexpected but handled situations
 * - error: Failures requiring attention
 */

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogContext {
  request_id?: string;
  user_id?: string;
  company_id?: string;
  method?: string;
  path?: string;
  status?: number;
  duration_ms?: number;
  [key: string]: unknown;
}

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context: LogContext;
}

/**
 * Log a structured message
 */
function log(level: LogLevel, message: string, context: LogContext = {}): void {
  const entry: LogEntry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    context,
  };
  
  // Output as single-line JSON for log aggregation
  const output = JSON.stringify(entry);
  
  switch (level) {
    case 'error':
      console.error(output);
      break;
    case 'warn':
      console.warn(output);
      break;
    default:
      console.log(output);
  }
}

export const logger = {
  debug: (message: string, context?: LogContext) => log('debug', message, context),
  info: (message: string, context?: LogContext) => log('info', message, context),
  warn: (message: string, context?: LogContext) => log('warn', message, context),
  error: (message: string, context?: LogContext) => log('error', message, context),
  
  /**
   * Log an HTTP request/response cycle
   */
  request: (
    request: Request,
    response: Response,
    context: LogContext & { duration_ms: number }
  ): void => {
    const url = new URL(request.url);
    const level: LogLevel = response.status >= 500 ? 'error' :
                            response.status >= 400 ? 'warn' : 'info';
    
    log(level, `${request.method} ${url.pathname} ${response.status}`, {
      method: request.method,
      path: url.pathname,
      status: response.status,
      ...context,
    });
  },
};
```

---

## 9. Error Handling

```typescript
// supabase/functions/api/utils/errors.ts

/**
 * Application error codes matching OpenAPI spec
 */
export type ErrorCode =
  | 'VALIDATION_ERROR'
  | 'AUTHENTICATION_ERROR'
  | 'AUTHORIZATION_ERROR'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'RATE_LIMITED'
  | 'DEPENDENCY_CONFLICT'
  | 'INTERNAL_ERROR'
  | 'SERVICE_UNAVAILABLE';

/**
 * Base application error
 */
export class AppError extends Error {
  constructor(
    public readonly code: ErrorCode,
    message: string,
    public readonly statusCode: number,
    public readonly details?: Record<string, unknown>
  ) {
    super(message);
    this.name = 'AppError';
  }
}

/**
 * Validation error with field-level details
 */
export class ValidationError extends AppError {
  constructor(
    message: string,
    public readonly errors: Array<{ field: string; message: string; code: string }>
  ) {
    super('VALIDATION_ERROR', message, 400, { errors });
    this.name = 'ValidationError';
  }
}

/**
 * Authentication error (missing/invalid token)
 */
export class AuthenticationError extends AppError {
  constructor(message: string = 'Authentication required') {
    super('AUTHENTICATION_ERROR', message, 401, {
      hint: 'Ensure Authorization header contains a valid Bearer token',
    });
    this.name = 'AuthenticationError';
  }
}

/**
 * Authorization error (valid token but insufficient permissions)
 */
export class AuthorizationError extends AppError {
  constructor(message: string = 'You do not have permission to perform this action') {
    super('AUTHORIZATION_ERROR', message, 403);
    this.name = 'AuthorizationError';
  }
}

/**
 * Resource not found
 */
export class NotFoundError extends AppError {
  constructor(resource: string = 'Resource') {
    super('NOT_FOUND', `${resource} not found`, 404);
    this.name = 'NotFoundError';
  }
}

/**
 * Conflict error (e.g., duplicate SKU)
 */
export class ConflictError extends AppError {
  constructor(message: string, field?: string) {
    super('CONFLICT', message, 409, field ? { field } : undefined);
    this.name = 'ConflictError';
  }
}

/**
 * Rate limit exceeded
 */
export class RateLimitError extends AppError {
  constructor(
    public readonly retryAfter: number,
    public readonly limit: number,
    public readonly resetAt: number
  ) {
    super('RATE_LIMITED', `Rate limit exceeded. Retry after ${retryAfter} seconds.`, 429, {
      limit,
      window_seconds: 60,
      retry_after: retryAfter,
    });
    this.name = 'RateLimitError';
  }
}
```

```typescript
// supabase/functions/api/utils/responses.ts

import { AppError, ValidationError, RateLimitError } from './errors.ts';

/**
 * Standard success response
 */
export function jsonResponse<T>(
  data: T,
  status: number = 200,
  headers: Headers = new Headers()
): Response {
  headers.set('Content-Type', 'application/json');
  
  return new Response(JSON.stringify(data), {
    status,
    headers,
  });
}

/**
 * Paginated list response
 */
export function paginatedResponse<T>(
  data: T[],
  meta: {
    total: number;
    limit: number;
    offset: number;
    filtered_total?: number;
  },
  headers: Headers = new Headers()
): Response {
  return jsonResponse({
    data,
    meta: {
      ...meta,
      has_more: meta.offset + data.length < meta.total,
    },
  }, 200, headers);
}

/**
 * No content response (for DELETE)
 */
export function noContentResponse(headers: Headers = new Headers()): Response {
  return new Response(null, { status: 204, headers });
}

/**
 * Created response with Location header
 */
export function createdResponse<T>(
  data: T,
  location: string,
  headers: Headers = new Headers()
): Response {
  headers.set('Location', location);
  return jsonResponse({ data }, 201, headers);
}

/**
 * Error response from AppError
 */
export function errorResponse(
  error: AppError,
  requestId: string,
  headers: Headers = new Headers()
): Response {
  // Add rate limit headers for rate limit errors
  if (error instanceof RateLimitError) {
    headers.set('Retry-After', error.retryAfter.toString());
    headers.set('X-RateLimit-Limit', error.limit.toString());
    headers.set('X-RateLimit-Remaining', '0');
    headers.set('X-RateLimit-Reset', error.resetAt.toString());
  }
  
  const body: Record<string, unknown> = {
    error: {
      code: error.code,
      message: error.message,
    },
    request_id: requestId,
    timestamp: new Date().toISOString(),
  };
  
  // Add validation errors if present
  if (error instanceof ValidationError) {
    (body.error as Record<string, unknown>).errors = error.errors;
  }
  
  // Add other details
  if (error.details) {
    Object.assign(body.error as Record<string, unknown>, error.details);
  }
  
  return jsonResponse(body, error.statusCode, headers);
}

/**
 * Internal error response (for unexpected errors)
 */
export function internalErrorResponse(requestId: string): Response {
  return jsonResponse({
    error: {
      code: 'INTERNAL_ERROR',
      message: 'An unexpected error occurred. Please try again or contact support.',
      details: {
        support_reference: 'Contact support with request_id',
      },
    },
    request_id: requestId,
    timestamp: new Date().toISOString(),
  }, 500);
}
```

---

## 10. Testing Strategy

### Unit Tests

```typescript
// supabase/functions/api/__tests__/schemas.test.ts

import { assertEquals, assertThrows } from 'https://deno.land/std/testing/asserts.ts';
import { inventoryCreateSchema } from '../schemas/inventory.ts';

Deno.test('inventoryCreateSchema - valid input', () => {
  const input = {
    name: 'Widget A',
    sku: 'WGT-001',
    quantity: 100,
  };
  
  const result = inventoryCreateSchema.parse(input);
  assertEquals(result.name, 'Widget A');
  assertEquals(result.quantity, 100);
});

Deno.test('inventoryCreateSchema - rejects negative quantity', () => {
  const input = {
    name: 'Widget A',
    sku: 'WGT-001',
    quantity: -5,
  };
  
  assertThrows(() => inventoryCreateSchema.parse(input));
});

Deno.test('inventoryCreateSchema - rejects invalid SKU characters', () => {
  const input = {
    name: 'Widget A',
    sku: 'WGT 001', // Space not allowed
    quantity: 100,
  };
  
  assertThrows(() => inventoryCreateSchema.parse(input));
});

Deno.test('inventoryCreateSchema - requires reorder_point with reorder_quantity', () => {
  const input = {
    name: 'Widget A',
    sku: 'WGT-001',
    quantity: 100,
    reorder_quantity: 50, // Missing reorder_point
  };
  
  assertThrows(() => inventoryCreateSchema.parse(input));
});
```

### Integration Tests

```bash
#!/bin/bash
# scripts/integration-test.sh

# Start local Supabase
supabase start

# Wait for services
sleep 5

# Get service URLs
SUPABASE_URL=$(supabase status --output json | jq -r '.API_URL')
ANON_KEY=$(supabase status --output json | jq -r '.ANON_KEY')

# Create test user and get JWT
TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/signup" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}' \
  | jq -r '.access_token')

# Run tests
echo "Testing GET /health..."
curl -s "$SUPABASE_URL/functions/v1/api/health" | jq .

echo "Testing GET /v1/inventory (unauthorized)..."
curl -s -w "\nStatus: %{http_code}\n" "$SUPABASE_URL/functions/v1/api/v1/inventory"

echo "Testing GET /v1/inventory (authorized)..."
curl -s -H "Authorization: Bearer $TOKEN" \
  "$SUPABASE_URL/functions/v1/api/v1/inventory" | jq .

echo "Testing POST /v1/inventory..."
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"name":"Test Widget","sku":"TEST-001","quantity":50}' \
  "$SUPABASE_URL/functions/v1/api/v1/inventory" | jq .

# Cleanup
supabase stop
```

### Test Commands

```bash
# Run unit tests
deno test supabase/functions/api/__tests__/ --allow-env

# Run integration tests
./scripts/integration-test.sh

# Type check
deno check supabase/functions/api/index.ts

# Lint
deno lint supabase/functions/api/
```

---

## 11. Deployment

### Local Development

```bash
# Start Supabase locally
supabase start

# Serve Edge Function with hot reload
supabase functions serve api --env-file .env.local

# Test locally
curl http://localhost:54321/functions/v1/api/health
```

### Production Deployment

```bash
# Deploy function
supabase functions deploy api --project-ref your-project-ref

# Set secrets
supabase secrets set --env-file .env.production

# Verify deployment
curl https://your-project-ref.supabase.co/functions/v1/api/health
```

---

## 12. Security Considerations

### Checklist

- [ ] **Never log JWTs or passwords**
- [ ] **Never use service-role key in API code**
- [ ] **Always use parameterized queries** (Supabase client does this)
- [ ] **Validate all input with Zod before processing**
- [ ] **Return 404 (not 403) for unauthorized resource access** — prevents enumeration
- [ ] **Set appropriate CORS origins** — never use `*` in production with credentials
- [ ] **Rate limit all endpoints**
- [ ] **Use HTTPS only** (Supabase handles this)
- [ ] **Keep dependencies updated** — `deno task update-deps`

### RLS Policies Reminder

The API relies on these RLS policies existing on the `inventory` table:

```sql
-- Users can only see their company's inventory
CREATE POLICY "Company isolation for inventory"
ON inventory
FOR ALL
USING (company_id = (auth.jwt() -> 'app_metadata' ->> 'company_id')::uuid);
```

**Never bypass these with service-role access.**

---

## Appendix: Environment Variables

```bash
# .env.local (local development)
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=your-local-anon-key
ENVIRONMENT=development

# .env.production
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_ANON_KEY=your-production-anon-key
ENVIRONMENT=production
```

---

*End of Implementation Guide*
