# Inventory Seeding Invariants

These are hard constraints for Company Inventory Seeding. Violations must fail.

- Seeding is company-scoped.
- Seeding is explicitly invoked; no automatic or background runs.
- Only super_user may seed across companies.
- No transaction history may be copied.
- No PII or supplier data may be copied.
- All seed operations are auditable.
- Inventory ownership is always reassigned to the target company.
