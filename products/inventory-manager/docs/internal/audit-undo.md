# Undo Actions

Feature ID: inventory.audit.undo

## Overview
Undo Actions allows authorized admins to roll back certain inventory actions using audit history. This capability is internal and admin-facing.

## Tier Availability
- Enterprise

## How It Works
- Undo uses the audit log to restore deleted items or revert edits.
- Access requires audit_log:view plus the underlying inventory permission (edit/restore/delete).
- Each undo operation records a rollback entry in the audit log.

## Limitations
- Only inventory_items actions are supported (insert/update/delete/bulk delete).
- Undo is not exposed to regular end users in the UI.
- Rollbacks depend on the original audit entry contents.

## Support Expectations
Requests may involve recovery guidance. Support should verify tier eligibility, permissions, and the presence of the original audit entry before proceeding.
