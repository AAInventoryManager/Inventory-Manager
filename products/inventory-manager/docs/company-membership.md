# Company Membership

Feature ID: inventory.auth.company_membership

## Overview
Company Membership defines how users are linked to a company and assigned a role (admin, member, or viewer). Roles drive the permissions the user receives in the app.

## Tier Availability
- Business
- Enterprise

## How It Works
- Each user is linked to exactly one company in Phase 1.
- The assigned role determines permissions through the Role Engine.
- Membership is created through invitations or admin assignment.

## Limitations
- One company per user (Phase 1 constraint).
- Roles are global and not customized per company.
- Super user status is managed separately and cannot be granted via standard role changes.

## Support Expectations
Users may need help understanding role differences or why access is limited. Support should verify the user’s role and company assignment.
