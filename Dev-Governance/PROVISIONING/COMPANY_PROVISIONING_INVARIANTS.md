# Company Provisioning Invariants

These are hard constraints for the Company Provisioning feature.
Violations must fail.

- Only super_user may provision companies.
- Provisioning is explicit; no automatic or background runs.
- Company slug must be unique and non-empty.
- Source and target company_id must differ for any inventory seed.
- Inventory seeding must follow INVENTORY_SEEDING_MODEL and
  INVENTORY_SEEDING_INVARIANTS.
- Seeding cannot copy quantities, transactions, or company-specific
  references (locations, categories).
- If subscription_tier is provided, it must be a valid tier and must be
  applied via the entitlement override workflow (no billing side effects).
- User assignments must reference existing users only.
- Roles are limited to: viewer, member, admin.
- super_user role cannot be assigned through provisioning UI.
- Cross-company memberships are allowed; provisioning must not remove or
  modify existing memberships for those users.
- At least one admin must exist for the new company (actor or assigned).
- All provisioning actions are auditable.
