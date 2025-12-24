# Phase 0 Governance Backfill Report

Objective: inventory all existing Inventory Manager features, register them in the feature registry, and identify governance gaps (docs, entitlements, tests). No remediation implemented.

Sources reviewed:
- `index.html` (UI flows and modals)
- `APP_REFERENCE.md` (feature descriptions)
- `supabase/migrations/*.sql` (tables, RPCs, RLS, triggers)
- `supabase/functions/*` (edge functions)
- `sw.js`, `manifest.webmanifest` (PWA)
- `tests/*` (coverage inventory)

Notes on registry placeholders:
- The schema does not allow legacy/unknown values, so temporary placeholders were used.
- Approved temporary mapping for legacy features:
  - `status: legacy`
  - `tier_availability` entries set to `starter: false`, `professional: false`, `business: false`, `enterprise: false`
  - `support_impact: low`

## Feature Inventory and Governance Status

### Auth and Access
- `inventory.auth.login` — Sources: `index.html` auth modal; Supabase Auth. Docs: missing. Entitlements: N/A. Tests: none. Gaps: add user-facing auth doc.
- `inventory.auth.profile_settings` — Sources: `index.html` profile modal; `profiles` table. Docs: missing. Entitlements: none beyond auth. Tests: none. Gaps: docs + preference validation tests.
- `inventory.auth.allowlist` — Sources: `authorized_users` table + `SUPABASE_SECURE_SETUP.sql`. Docs: missing. Entitlements: unclear enforcement (table exists, no runtime use found). Tests: none. Gaps: decide deprecation or enforcement; docs.
- `inventory.auth.company_membership` — Sources: `company_members` table, `get_my_companies`, RLS. Docs: missing. Entitlements: role-based RLS only. Tests: partial (RLS company_members). Gaps: tier/entitlement rules + docs.
- `inventory.auth.company_switcher` — Sources: profile company select UI, `get_my_companies`. Docs: missing. Entitlements: super user only (backend + UI). Tests: none. Gaps: docs + entitlement tests.
- `inventory.auth.invite_users` — Sources: invite modal; `invite_user`, `accept_invitation`. Docs: missing. Entitlements: role-based (admin/super). Tests: none. Gaps: docs + entitlement tests.
- `inventory.auth.user_management` — Sources: user management modal; `remove_company_member`, `set_super_user`. Docs: missing. Entitlements: admin or super-user checks only. Tests: none. Gaps: docs + entitlement tests.
- `inventory.auth.role_requests` — Sources: role request modal; `request_role_change`, `process_role_request`, `role_change_requests` table. Docs: missing. Entitlements: admin/super-user checks only. Tests: none. Gaps: docs + entitlement tests.
- `inventory.auth.roles` — Sources: role manager modal; `role_configurations`, `check_permission`, `get_user_permissions`. Docs: present (`products/inventory-manager/docs/role-engine.md`). Entitlements: tier + permission enforced. Tests: none. Gaps: tests for role engine flows.

### Inventory Core
- `inventory.inventory.core` — Sources: inventory table UI; `inventory_items` table, RLS, CRUD. Docs: missing. Entitlements: role-based RLS only. Tests: partial (RLS items). Gaps: docs + tier entitlements + CRUD tests.
- `inventory.inventory.batch_edit` — Sources: multi-select batch edit logic in UI. Docs: missing. Entitlements: UI only, relies on item permissions. Tests: none. Gaps: docs + tests.
- `inventory.inventory.realtime_sync` — Sources: Supabase realtime channel for `inventory_items`. Docs: missing. Entitlements: RLS-based. Tests: none. Gaps: docs + realtime behavior tests.
- `inventory.inventory.import_export` — Sources: import/paste flows; CSV export. Docs: missing. Entitlements: UI gating only. Tests: unit tests for parsing only. Gaps: docs + integration tests.
- `inventory.inventory.low_stock` — Sources: low stock thresholds/LEDs; profile prefs; report UI. Docs: missing. Entitlements: none beyond auth. Tests: none. Gaps: docs + enforcement rules.
- `inventory.inventory.reorder` — Sources: `reorder_enabled` + reorder fields in `inventory_items`. Docs: missing. Entitlements: none beyond auth. Tests: none. Gaps: docs + tests.
- `inventory.inventory.categories` — Sources: `inventory_categories` table and validation triggers. Docs: missing. Entitlements: RLS only. Tests: none. Gaps: docs + UI/API exposure decision.
- `inventory.inventory.locations` — Sources: `inventory_locations` table and validation triggers. Docs: missing. Entitlements: RLS only. Tests: none. Gaps: docs + UI/API exposure decision.
- `inventory.inventory.transactions` — Sources: `inventory_transactions` table + validation trigger. Docs: missing. Entitlements: RLS only. Tests: none. Gaps: no UI/API usage; document or deprecate.
- `inventory.inventory.trash` — Sources: trash modal; `soft_delete_item(s)`, `restore_item`, `get_deleted_items`. Docs: missing. Entitlements: role-based RLS + RPC checks. Tests: partial (soft delete). Gaps: docs + restore tests.

### Orders
- `inventory.orders.cart` — Sources: order modal/cart UI; `orders` table. Docs: missing. Entitlements: role-based RLS only. Tests: none. Gaps: docs + tier enforcement + tests.
- `inventory.orders.email_send` — Sources: send order UI + `supabase/functions/send-order`. Docs: missing. Entitlements: function only checks API key/inputs; no tier gating. Tests: none. Gaps: docs + entitlement checks + tests.
- `inventory.orders.history` — Sources: order history modal; order receive actions. Docs: missing. Entitlements: role-based RLS only. Tests: none. Gaps: docs + tests.
- `inventory.orders.recipients` — Sources: `order_recipients` table; suggestion UI. Docs: missing. Entitlements: RLS only. Tests: none. Gaps: docs + tests.
- `inventory.orders.trash` — Sources: `soft_delete_order`, `restore_order`; trash UI. Docs: missing. Entitlements: role-based RLS only. Tests: none. Gaps: docs + tests.

### Reports and Analytics
- `inventory.reports.inventory` — Sources: inventory report modal, CSV/email. Docs: missing. Entitlements: UI gating only. Tests: none. Gaps: docs + tests.
- `inventory.reports.low_stock_api` — Sources: edge API handler uses `get_low_stock_items`. Docs: missing. Entitlements: API auth only. Tests: none. Gaps: RPC appears missing in migrations; enforce/implement or deprecate.
- `inventory.metrics.action_metrics` — Sources: `action_metrics` table; `get_action_metrics`. Docs: missing. Entitlements: super-user only RPC; no tier checks. Tests: none. Gaps: docs + entitlements + tests.
- `inventory.metrics.platform_summary` — Sources: `get_platform_metrics`. Docs: missing. Entitlements: super-user only; no tier checks. Tests: none. Gaps: docs + tier enforcement.
- `inventory.metrics.dashboard` — Sources: metrics modal; `get_company_dashboard_metrics`, `get_platform_dashboard_metrics`. Docs: present (`products/inventory-manager/docs/metrics-dashboard.md`). Entitlements: tier + permission enforced. Tests: none. Gaps: tests for metrics RPCs.

### Snapshots and Audit
- `inventory.snapshots.core` — Sources: `inventory_snapshots`, `create_snapshot`, `restore_snapshot`. Docs: missing. Entitlements: super-user/admin checks only; tier checks in `get_snapshots` only. Tests: none. Gaps: docs + tier enforcement for create/restore.
- `inventory.snapshots.ui` — Sources: snapshots modal; `get_snapshots` RPC. Docs: present (`products/inventory-manager/docs/snapshots-ui.md`). Entitlements: tier + permission enforced. Tests: none. Gaps: tests for UI/RPC.
- `inventory.audit.log` — Sources: `audit_log` table + `get_audit_log` RPC + audit modal. Docs: missing. Entitlements: admin/super-user only. Tests: none. Gaps: docs + tests.
- `inventory.audit.undo` — Sources: `undo_action` RPC. Docs: missing. Entitlements: admin/super-user only. Tests: none. Gaps: docs + tests.

### Admin and Platform
- `inventory.admin.company_management` — Sources: `create_company`, `get_all_companies`. Docs: missing. Entitlements: super-user only. Tests: none. Gaps: docs + tests.
- `inventory.admin.user_directory` — Sources: `get_all_users`. Docs: missing. Entitlements: super-user only. Tests: none. Gaps: docs + tests.
- `inventory.admin.member_management` — Sources: `remove_company_member`, `set_super_user`. Docs: missing. Entitlements: admin or super-user only. Tests: none. Gaps: docs + tests.

### Platform Infrastructure
- `inventory.pwa.offline` — Sources: `sw.js`, `manifest.webmanifest`. Docs: missing. Entitlements: N/A. Tests: none. Gaps: docs + offline behavior tests.
- `inventory.api.edge` — Sources: `supabase/functions/api/*` (REST API + `/health`). Docs: missing. Entitlements: API auth, rate limit middleware. Tests: none. Gaps: uses `inventory` table and `adjust_inventory_quantity` RPC not found in migrations; fix or deprecate.

## Governance Gaps Summary (Global)

- Tier enforcement is missing for most legacy features outside Snapshots UI, Metrics Dashboard, and Role Engine.
- User-facing docs are missing for nearly all legacy features (only Phase 1B docs exist).
- Entitlement tests are missing for orders, reports, audit, snapshots core, and admin tools.
- Edge API appears out of sync with database schema (`inventory` table, `adjust_inventory_quantity`, `get_low_stock_items`).
- `authorized_users` allowlist exists but no runtime usage found (legacy drift).
- `inventory_transactions` exists without UI/API exposure or docs.

## Required Remediation (Per Feature)

1) Documentation backlog: create user-facing docs for all legacy features and internal docs for admin-only tools.
2) Entitlement enforcement: define tier availability per legacy feature and enforce in backend (RLS/RPC).
3) Tests: add integration tests for orders, audit, snapshots core, metrics, and admin RPCs.
4) Legacy cleanup decisions: reconcile edge API schema drift, `authorized_users` allowlist, and unused tables (transactions).

Stop condition reached: discovery complete and report delivered. Await approval before remediation.
