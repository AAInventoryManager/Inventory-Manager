# Inventory Manager API

Production-grade REST API for the Inventory Manager application, built on Supabase Edge Functions.

## Architecture

```
┌──────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│   Client     │────▶│  Supabase Edge Fn   │────▶│  PostgreSQL      │
│  (JWT Auth)  │     │  (Deno + TypeScript)│     │  (with RLS)      │
└──────────────┘     └─────────────────────┘     └──────────────────┘
```

## Key Features

- **Multi-tenant**: Row Level Security enforces data isolation at database level
- **Type-safe**: Zod schemas validate all inputs before database operations
- **Idempotent**: POST/PATCH operations support idempotency keys
- **Rate-limited**: Per-user rate limiting with tier support
- **Observable**: Structured JSON logging for all requests
- **Documented**: OpenAPI 3.1 specification included

## Project Structure

```
supabase/
├── migrations/
│   └── 001_initial_schema.sql    # Database schema + RLS policies
│
└── functions/
    └── api/
        ├── index.ts              # Main router
        │
        ├── middleware/
        │   ├── cors.ts           # CORS handling
        │   ├── auth.ts           # JWT validation
        │   ├── rate-limit.ts     # Rate limiting
        │   └── request-id.ts     # Request ID generation
        │
        ├── handlers/
        │   ├── health.ts         # GET /health
        │   ├── inventory.ts      # CRUD operations
        │   └── reports.ts        # Low-stock report
        │
        ├── schemas/
        │   ├── common.ts         # Shared Zod schemas
        │   ├── inventory.ts      # Inventory schemas
        │   └── pagination.ts     # Query param schemas
        │
        └── utils/
            ├── errors.ts         # Error classes
            ├── responses.ts      # Response helpers
            ├── logger.ts         # Structured logging
            └── validate.ts       # Validation helpers
```

## Quick Start

### Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) installed
- Deno installed (for local development)

### Local Development

```bash
# Start local Supabase
supabase start

# Apply migrations
supabase db reset

# Serve Edge Function with hot reload
supabase functions serve api --env-file .env.local

# Test health endpoint
curl http://localhost:54321/functions/v1/api/health
```

### Production Deployment

```bash
# Link to your Supabase project
supabase link --project-ref your-project-ref

# Deploy database migrations
supabase db push

# Deploy Edge Function
supabase functions deploy api

# Set environment secrets
supabase secrets set --env-file .env.production
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check (no auth) |
| GET | `/v1/inventory` | List inventory items |
| POST | `/v1/inventory` | Create inventory item |
| GET | `/v1/inventory/:id` | Get single item |
| PATCH | `/v1/inventory/:id` | Update item |
| DELETE | `/v1/inventory/:id` | Delete item |
| POST | `/v1/inventory/bulk` | Bulk create items |
| POST | `/v1/inventory/:id/adjust` | Adjust quantity |
| GET | `/v1/inventory/low-stock` | Low stock report |

## Authentication

All endpoints (except `/health`) require a valid Supabase JWT:

```bash
curl -H "Authorization: Bearer <your_jwt>" \
  https://your-project.supabase.co/functions/v1/api/v1/inventory
```

## Documentation

- `inventory-manager-api-spec.yaml` - OpenAPI 3.1 specification
- `inventory-manager-api-implementation-guide.md` - Detailed implementation guide

## Security Model

1. **JWT Authentication**: All API requests require valid Supabase JWT
2. **Row Level Security**: Database enforces data isolation by company_id
3. **No Service-Role Keys**: API never bypasses RLS
4. **Input Validation**: Zod schemas validate all input before processing
5. **Rate Limiting**: Prevents abuse and ensures fair usage

## Environment Variables

```bash
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
ENVIRONMENT=production  # or 'development'
```

## License

Proprietary - All rights reserved
