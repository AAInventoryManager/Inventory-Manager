# Company Tier Model

## Purpose
Define the canonical, company-scoped subscription tier model, including
manual overrides and time-limited grants. This document is authoritative
for entitlement resolution and backend enforcement.

## Scope
- Company-level subscription tiers only.
- Manual overrides and time-limited grants.
- Deterministic effective-tier resolution.

## Definitions
- Base tier: The subscription tier derived from billing for a company.
- Override tier: A manually assigned tier for a company, optionally time-limited.
- Effective tier: The tier used for entitlement enforcement.

## Base Subscription Tier
- Base tier is company-scoped and derived from billing subscriptions.
- If no active subscription exists, base tier = starter.
- Tier order is defined in `Dev-Governance/ENTITLEMENT_MODEL.md`.

## Override Tier
- Overrides are company-scoped and created by super_user only.
- Overrides can be upgrades or downgrades.
- Overrides may be time-limited via `starts_at` and `ends_at`.
- Overrides supersede base tier while active.

## Override Timing Semantics
- `starts_at` is the earliest time an override can take effect.
- `ends_at` is the exclusive upper bound for override validity.
- An override is active if:
  - `starts_at <= now()`, and
  - `ends_at` is NULL or `now() < ends_at`, and
  - `revoked_at` is NULL.
- Expired overrides are ignored automatically.

## Manual Revocation
- A super_user may revoke an active override by setting `revoked_at`.
- Revocation is terminal; the override does not become active again.
- Revocation immediately reverts effective tier to base tier.

## Constraints
- At most one active override per company at any time.
- Overlapping overrides are rejected.
- Overrides are company-scoped only; no per-user tiers.

## Effective Tier Resolution Algorithm
1. Determine base tier from billing. If no active subscription exists,
   base tier = starter.
2. Query for the single active override where:
   `starts_at <= now()` AND (`ends_at` IS NULL OR `now() < ends_at`) AND
   `revoked_at` IS NULL.
3. If an active override exists, effective tier = override tier.
4. Otherwise, effective tier = base tier.

## Data Model (Governing Fields)
- `company_tier_overrides` (append-only history)
  - company_id
  - override_tier
  - starts_at
  - ends_at (nullable)
  - created_by
  - created_at
  - revoked_at (nullable)

## Assumptions
- All timestamps are stored as TIMESTAMPTZ and compared using database `now()`.
- Billing-derived base tier resolution is authoritative and server-side.
