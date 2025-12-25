# Changelog

## Unreleased
- [inventory.snapshots.ui] Added user-facing documentation for the read-only Snapshots UI.
- [inventory.metrics.dashboard] Added user-facing documentation for the Metrics Dashboard.
- [inventory.auth.roles] Added user-facing documentation for the Role Engine.
- [inventory.security.checklist] Added internal security testing checklist documentation.
- [inventory.snapshots.ui] Implemented snapshots modal with preview and tier gating.
- [inventory.metrics.dashboard] Implemented metrics dashboard modal and metrics RPCs.
- [inventory.auth.roles] Implemented role manager modal with permission RPCs and tier gating.
- [inventory.audit.log] Added audit log documentation and enterprise-tier enforcement.
- [inventory.audit.undo] Added internal undo-action documentation and permission enforcement.
- [inventory.auth.user_management] Enforced Business tier and permission checks for member management.
- [inventory.auth.invite_users] Enforced Business tier and permission checks for invitations.
- [inventory.auth.role_requests] Enforced Business tier and permission checks for role requests.
- [inventory.metrics.dashboard] Enforced Professional tier and permission checks for metrics RPCs.
- [inventory.metrics.platform_summary] Enforced Professional tier access for platform metrics.
- [inventory.reports.inventory] Added inventory report documentation.
- [inventory.reports.low_stock_api] Added low stock API documentation and RPC enforcement.
- [inventory.orders.cart] Enforced Business tier and permission checks for order builder workflows.
- [inventory.orders.email_send] Added Business tier and permission checks for order email sending.
- [inventory.orders.history] Added order history documentation and Business-tier enforcement.
- [inventory.orders.recipients] Added order recipient documentation and Business-tier enforcement.
- [inventory.orders.trash] Enforced Business tier and permission checks for order delete/restore.
- [inventory.orders.cart] Added company-managed shipping addresses and PO identifiers to order builder.
- [inventory.orders.email_send] Enforced PO-based subject format, sender reply-to, and company name requirement.
- [inventory.orders.history] Persisted PO identifiers and shipping address snapshots in order history and export.
- [inventory.audit.log] Added collapsed entries, free-text filtering, and CSV export.
- [inventory.auth.profile_settings] Removed delivery address from profile settings.
- [inventory.inventory.core] Enforced inventory CRUD permissions and documented core workflows.
- [inventory.inventory.batch_edit] Documented batch edit behavior for inventory updates.
- [inventory.inventory.import_export] Enforced Professional tier for bulk import/export and documented behavior.
- [inventory.inventory.trash] Enforced inventory trash permissions and documented restore flow.

## v1.0.2 — UI polish, sorting, PWA
- Header alignment: title/status left, logo right; constrained to table width
- Title styling: larger, bolder NASA-like font (Barlow)
- Sortable columns: Item/Description/Qty with persistent sort and arrows
- Description column: dynamic width on desktop, wraps on mobile
- Status text: embedded version + uppercase state; pill removed
- PWA: added icons (192/512), bumped SW cache to v14; manifest v4

## v1.0.1 — Server-first UI and connectivity
- Server-only rendering: snapshot load + realtime; no local item copies
- Offline edits blocked; status banner shows Connected/Offline
- Server-first Add/Edit/Delete/Import with post-refresh from server
- Service worker cache bumped to v12; manifest cache param v3
- Manifest tweaks: start_url './', short_name "Inventory", version 1.0.1

## v1.0.0 — Initial stable release
- iOS-friendly, offline-capable inventory tracker
- Supabase sync (items: id, name, description, qty) with realtime updates
- Import: file (CSV/TSV/TXT/JSON/XLSX/DOCX) + paste modal with preview
- Inline editing (Enter=save, Esc=cancel), live filter, bulk delete, CSV export
- PWA: manifest + service worker (immediate takeover), cache v9
- Multi-step Undo (last 5 ops), empty-state UI, basic error logging
