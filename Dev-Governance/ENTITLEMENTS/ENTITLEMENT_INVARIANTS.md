# Entitlement Invariants

These are hard constraints and must be enforced server-side.

1. Subscription tiers are company-scoped only; no per-user subscription tiers.
2. Overrides require super_user authority and are validated server-side.
3. Client-supplied tier values are never trusted for entitlement decisions.
4. Effective tier resolution occurs only on the backend.
5. Overrides are company-scoped only; they do not follow users across companies.
6. Only one active override is permitted per company at any time.
7. Overlapping or concurrent overrides are rejected.
8. Expired overrides are ignored automatically without manual intervention.
9. Historical override records are immutable and append-only.
10. Revocation is a terminal state update; original override fields are not edited.
11. Audit records are append-only and cannot be modified or deleted.
12. Super_user bypass applies to enforcement checks, not to audit requirements.
