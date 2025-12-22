# Inventory Manager – REST API Build (Codex Prompt)

## Purpose

You are an expert backend and systems integration engineer.

We have an existing production web application called **Inventory Manager** that:

- Is a static frontend (HTML, Cascading Style Sheets, JavaScript)
- Uses Supabase for:
  - Authentication
  - PostgreSQL database
  - Realtime updates
- Is already working in production and MUST NOT BREAK

Your task is to **ADD a REST Application Programming Interface (API) layer** in a **safe, incremental, backward-compatible way**.

The API must:

- Not break or modify existing frontend behavior
- Not require frontend rewrites
- Preserve all current database schemas
- Preserve Supabase Row Level Security (RLS)
- Be suitable for future third-party integrations

The API will be built using **Supabase Edge Functions** (Deno + TypeScript).

DO NOT:

- Remove or bypass RLS
- Introduce service-role access for public endpoints
- Change existing tables unless explicitly instructed
- Rewrite frontend logic

---

## 1. Architecture Explanation (NO CODE YET)

Before writing any code:

1. Explain the architecture in plain language:

   - Where the API lives
   - How requests flow from client → API → database
   - Why this API layer does not break the existing app

2. Explain what a Supabase Edge Function is in this context
3. Explain how authentication works for API requests
4. Explain how permissions remain enforced through RLS

Use simple language and define all acronyms on first use.

---

## 2. API Design (Contract First)

Design a **versioned REST API** using these principles:

- Base path: `/functions/v1/api`
- Versioned routes (`v1`)
- JavaScript Object Notation (JSON) input and output
- Clear, consistent error responses
- Designed for third-party system integration

Define (DO NOT IMPLEMENT YET) the following endpoints:

- GET `/inventory`
- POST `/inventory`
- PATCH `/inventory/:id`
- DELETE `/inventory/:id`
- GET `/inventory/low-stock`

For EACH endpoint, document:

- Purpose
- Inputs
- Outputs
- Authentication requirements
- Authorization behavior
- Failure cases

---

## 3. Authentication and Security Model

Explain and implement authentication with these rules:

- All API requests require a valid Supabase JavaScript Web Token (JWT)
- Token is passed via HTTP header:

Authorization: Bearer

- Use a Supabase server client inside Edge Functions
- Rely on Row Level Security for authorization
- DO NOT bypass RLS with service-role keys

Explain:

- Why service-role keys are dangerous for public APIs
- How RLS protects against cross-company data leakage
- How this design supports future multi-tenant expansion

---

## 4. File and Folder Structure

Create the following Supabase Edge Function structure:

supabase/
functions/
api/
index.ts
inventory.ts
auth.ts
responses.ts

Explain the responsibility of each file and why this separation improves maintainability.

---

## 5. Shared Utilities (IMPLEMENT FIRST)

Before implementing endpoints, create shared helpers.

### auth.ts

- Extract and validate JWT from request headers
- Create a Supabase client scoped to the authenticated user
- Fail securely if authentication is missing or invalid

### responses.ts

- Standard success response helper
- Standard error response helper
- Consistent HTTP status code handling

Explain each helper before showing code.

---

## 6. Inventory Endpoints (Incremental Implementation)

Implement endpoints one at a time.

### First endpoint: GET `/inventory`

Requirements:

- Return only inventory items the user is authorized to see
- Use Supabase client with RLS enforcement
- Support optional query parameters:
  - `search`
  - `limit`
  - `offset`

Explain:

- Query structure
- Why filtering belongs in the API instead of the frontend

After GET `/inventory`, implement in this order:

1. POST `/inventory`
2. PATCH `/inventory/:id`
3. DELETE `/inventory/:id`
4. GET `/inventory/low-stock`

For EACH endpoint:

- Explain the business problem it solves
- Explain how it maps to existing database tables
- Show implementation code
- Show example HTTP request
- Show example HTTP response

---

## 7. Local Development, Testing, and Deployment

Provide exact steps and commands to:

- Run Edge Functions locally
- Test endpoints using:
  - curl
  - Postman
- Deploy functions to Supabase

Include:

- Common failure modes
- Authentication debugging tips
- Authorization troubleshooting guidance

---

## 8. Backward Compatibility Verification

Explicitly verify and explain:

- Existing Inventory Manager frontend continues to work unchanged
- API is additive, not disruptive
- Database schema remains intact
- RLS remains the single source of truth for authorization
- Frontend can optionally migrate to API usage later

Explain how we know this approach is safe.

---

## 9. Future Expansion (DOCUMENT ONLY – NO CODE)

Document (do not implement) how this API could later support:

- Integration with employee management systems
- Webhooks
- API keys for non-user systems
- Multi-tenant Software as a Service (SaaS) model
- Rate limiting
- Auditing and logging

---

## 10. Teaching Constraint (MANDATORY)

Throughout the entire implementation:

- Explain WHY decisions are made
- Define acronyms on first use
- Avoid unexplained jargon
- Assume the reader is technical but learning backend APIs
- Prefer clarity and correctness over cleverness

---

## End of Prompt
