# Diagnostics Module Governance

## What It Is
The Diagnostics module is a super_user-only observability surface that explains
entitlements and enforcement behavior. It supports session-scoped simulation and
read-only metric previews to help validate governance rules without mutating data.

## What It Is Not
- It is not a test runner.
- It is not a data mutation surface.
- It is not a tier bypass.
- It is not a company management or provisioning tool.

## Simulation Rules
- Simulation is session-scoped and does not persist.
- No simulation state is written to the database.
- Simulation does not change backend authorization or entitlements.
- Simulation is for UI and diagnostic preview context only.

## Metric Preview Invariants
- Uses governed metric definitions and real formulas.
- Enforces tier rules exactly as production.
- Read-only: no writes and no side effects.
- Returns metric_id, value, unit, precision, time_context, and tier evaluation.

## Tier Enforcement Never Bypassed
- Tier enforcement remains authoritative on the backend.
- super_user bypass is explicit and server-verified.
- Client-provided tier values are non-authoritative.

