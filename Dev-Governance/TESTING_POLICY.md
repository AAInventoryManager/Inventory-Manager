# Testing Policy

## Purpose
This document defines the mandatory testing requirements for all software developed under this workspace.

Testing is a contractual verification mechanism.
Its purpose is to ensure features behave as specified, enforced, and priced.

Manual testing is exploratory only.
Automated testing is the acceptance criterion.

---

## Scope
This policy applies to:
- All products under /products/*
- All new features and feature modifications
- All backend enforcement logic
- All tier, entitlement, and permission behavior

No exceptions are implied by speed, convenience, or feature size.

---

## Core Principles

1. Backend enforcement is the source of truth.
2. UI behavior must reflect backend decisions, not replace them.
3. Entitlement violations are critical defects.
4. Tests must be deterministic and repeatable.
5. Tests must fail loudly and diagnostically.

---

## Required Test Layers

Every feature MUST be validated at the appropriate layers.

---

### 1) Unit Tests
Purpose:
- Verify pure logic behaves correctly.

Required when:
- New helper functions are added
- Tier fallback logic exists
- Permission resolution logic is introduced

Examples:
- Tier fallback defaults to Starter
- Permission checks return expected booleans

---

### 2) Entitlement / Policy Tests (Mandatory)
Purpose:
- Verify backend enforcement independent of UI.

Required when:
- Features are tier-gated
- Role-based access control is involved
- RPCs or RLS policies change

Rules:
- Tests must call backend logic directly
- UI must not be involved
- Both allowed and denied cases must be tested

---

### 3) Integration Tests
Purpose:
- Verify full backend request paths.

Required when:
- New RPCs are added
- RLS policies are modified
- Cross-table enforcement exists

Rules:
- Use seeded test data
- Validate end-to-end behavior

---

### 4) Edge Function Tests (Mandatory for tier-gated features)
Purpose:
- Verify edge functions enforce tier and permission checks correctly.
- Ensure deployed functions reflect current RPC and policy logic.

Required when:
- Edge functions call tier-checking RPCs (`has_tier_access`, `effective_company_tier`)
- Edge functions enforce permission checks (`check_permission`)
- Migrations modify tier resolution or permission logic

Rules:
- Tests must call the deployed edge function endpoint, not just underlying RPCs
- Both allowed and denied tier scenarios must be tested
- Edge functions must be redeployed after any migration that modifies:
  - `has_tier_access`
  - `effective_company_tier`
  - `check_permission`
  - Any RLS policy referencing tiers or permissions

Deployment trigger rule:
- Any PR that includes tier/permission migration changes MUST also redeploy affected edge functions
- CI pipeline should include: `supabase functions deploy <function-name>` after `supabase db push`

Example test cases:
```typescript
describe('send-order edge function', () => {
  it('returns 403 for Starter tier company', async () => {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-order`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${starterUserToken}` },
      body: JSON.stringify({ to: 'test@example.com', subject: 'Test', html: '<p>Test</p>' })
    });
    expect(res.status).toBe(403);
  });

  it('returns 200 for Business tier company', async () => {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-order`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${businessUserToken}` },
      body: JSON.stringify({ to: 'test@example.com', subject: 'Test', html: '<p>Test</p>' })
    });
    expect(res.status).toBe(200);
  });
});
```

---

### 5) UI Smoke Tests (Optional)
Purpose:
- Ensure UI reflects backend enforcement.

Rules:
- Do not assert business logic
- Do not duplicate backend tests
- Minimal coverage only

---

## Feature Completion Rule

A feature is complete only when:
- Governance review passes
- Required automated tests are present
- Tests pass OR skipped tests are explicitly justified
- Edge functions are redeployed if tier/permission logic changed
- End-to-end tier enforcement is verified via edge function calls

Manual testing alone is never sufficient.

---

## Failure Handling

When tests fail:
- Output must include expected vs actual behavior
- Root cause must be identifiable
- Fixes must be applied to code, not specifications

---

## Final Rule

If behavior cannot be tested automatically,
it is not yet safe to ship.
