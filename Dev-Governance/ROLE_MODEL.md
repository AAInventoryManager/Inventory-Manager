# Role Model

## Roles

### viewer
- Read-only access to permitted views

### member
- Read + create/edit where permitted

### admin
- Full company access within the permissions configured for the admin role

### super_user
- Platform owner role
- Can access all companies
- Always passes permission checks
- Bypasses tier checks for gated features

## Role Permissions
Role permissions are defined in role_configurations and enforced server-side via check_permission().

## Separation of Concerns
Role permissions do not determine tier entitlements. Tier checks are separate and mandatory.
