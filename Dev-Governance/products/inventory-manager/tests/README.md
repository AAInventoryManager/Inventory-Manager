# Inventory Manager — Test Suite

This directory contains automated tests for Inventory Manager.

Testing is governed by:
- TESTING_POLICY.md
- FEATURE_REGISTRY.yaml
- pricing.md
- PAYMENTS_AND_ENTITLEMENTS.md

---

## Directory Structure

unit/
- Pure logic and helper tests

entitlements/
- Tier, role, and permission enforcement tests
- Backend-first, no UI involvement

integration/
- End-to-end backend request tests
- RPC + RLS + data validation

ui/
- Minimal smoke tests
- UI reflects backend enforcement only

---

## Enforcement Rules

- Entitlement tests are mandatory for tier-gated features
- UI tests do not replace backend tests
- Tests must fail deterministically

Manual testing is exploratory only.
