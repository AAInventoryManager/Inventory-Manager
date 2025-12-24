# Role Engine

Feature ID: inventory.auth.roles

## Overview
The Role Engine centralizes permission control for inventory actions. It defines what each role can do and lets super users adjust role permissions for the platform.

## Tier Availability
- Business
- Enterprise

## How It Works
- Roles are stored globally in role_configurations with permissions in JSON.
- Super users can open the Role Manager UI to update permissions for admin, member, and viewer roles.
- Permission checks in the app reference the stored permissions for the active company.

## Limitations
- Role permissions are global, not per-company.
- Super user permissions are fixed and cannot be modified.
- Changes apply to all users in the role immediately after refresh.

## Support Expectations
This feature is expected to drive onboarding and configuration questions. Support should verify role intent, review permission changes, and confirm the impact scope before advising users to change roles.
