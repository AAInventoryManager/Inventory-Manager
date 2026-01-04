# Security Boundaries

## UI vs Backend
- UI gating is advisory only.
- Backend authorization is authoritative and enforced via RLS, RPCs, and Edge Functions.
- UI must never be the sole enforcement mechanism.

## Tier Enforcement
- Tier checks are enforced server-side with has_tier_access().
- Super users bypass tier checks in backend logic.

## Override Writes
- Manual tier overrides must go through governed RPCs.
- UI must not write tier fields directly.

## Auditability
- Tier override changes must be auditable.
- Audit fields and audit_log entries capture who, when, and why.

## Determinism
- Tier resolution is deterministic and does not depend on UI state.
- Missing or ambiguous billing state defaults to the most restrictive tier.
