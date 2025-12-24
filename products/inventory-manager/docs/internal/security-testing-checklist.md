# Security Testing Checklist

Feature ID: inventory.security.checklist

## Overview
This checklist defines internal security validation steps for Inventory Manager releases. It is not user-facing and is intended for engineering and release readiness reviews.

## Scope
- RLS enforcement
- Role-based access boundaries
- Soft delete integrity
- Audit log completeness
- Snapshot safety checks

## Checklist
- Cross-company isolation verified across inventory, orders, snapshots, and audit logs.
- Viewer role cannot create, update, or delete records.
- Member role cannot delete or manage users.
- Admin role cannot restore snapshots.
- Super user can access all companies and restore snapshots.
- Direct DELETE is blocked on business tables.
- Soft delete and restore flows are logged appropriately.
- Snapshot restore creates a pre-restore backup.

## Support Expectations
None. This is internal-only documentation.
