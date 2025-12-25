# Audit Log

Feature ID: inventory.audit.log

## Overview
The Audit Log provides a read-only history of inventory and order changes for the active company. It helps admins review who changed what and when.

## Tier Availability
- Enterprise

## How It Works
- The audit log is populated automatically from inventory and order activity.
- Entries include action type, table, user, and before/after values.
- Access is permission-driven and requires audit_log:view.
- Entries load collapsed by default; expand a row to view details.
- Filters include action, table, and free-text search.
- CSV export respects the current filters.

## Limitations
- Read-only; entries cannot be edited or deleted.
- Only tables wired to audit triggers appear.
- CSV export includes only the currently loaded entries.

## Support Expectations
Admins may ask about missing actions or entries. Support should confirm which tables/actions are audited and verify the company tier and permissions.
