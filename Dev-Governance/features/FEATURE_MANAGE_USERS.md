# Feature: Manage Users & Role Assignment

> Governance specification for company-scoped user management.

---

## Overview

The Manage Users feature enables authorized company administrators to view, invite, and manage users within their organization. This includes role assignment, which determines what actions each user can perform within the company context.

This feature is company-scoped—administrators can only manage users belonging to their own company.

---

## Problem Statement

Organizations using the Inventory Manager need to:

1. **Onboard team members** — Invite new users to join the company
2. **Control access levels** — Assign appropriate roles based on job function
3. **Maintain security** — Revoke access or adjust permissions as needs change
4. **Audit membership** — View current team composition and roles

Without this feature, all users would have identical permissions, creating security and accountability gaps.

---

## Feature Scope

### Scope Classification

| Attribute | Value |
|-----------|-------|
| Scope Type | Company-scoped |
| Tier Availability | Business, Enterprise |
| Authorization Model | Permission-based |
| UI Location | User Management Modal |

### Boundary Definition

```
┌─────────────────────────────────────────┐
│           COMPANY BOUNDARY              │
│                                         │
│  ┌─────────────┐    ┌─────────────┐    │
│  │   Admin A   │    │   Admin B   │    │
│  │  (manages)  │    │  (manages)  │    │
│  └──────┬──────┘    └──────┬──────┘    │
│         │                  │           │
│         ▼                  ▼           │
│  ┌─────────────────────────────────┐   │
│  │      Company Members            │   │
│  │  - Member 1 (role: member)      │   │
│  │  - Member 2 (role: viewer)      │   │
│  │  - Member 3 (role: admin)       │   │
│  └─────────────────────────────────┘   │
│                                         │
└─────────────────────────────────────────┘
          ▲
          │ CANNOT ACCESS
          ▼
┌─────────────────────────────────────────┐
│         OTHER COMPANY                   │
└─────────────────────────────────────────┘
```

---

## In-Scope Capabilities

### 1. View Company Members

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:view` |
| Data Returned | User ID, email, display name, role, join date, status |
| Scope | Own company only |

### 2. Invite New Users

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:invite` |
| Mechanism | Email invitation with role pre-assignment |
| Constraints | Cannot invite existing company members |
| Scope | Own company only |

### 3. Assign / Change Roles

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:manage` |
| Available Roles | viewer, member, admin |
| Constraints | See forbidden transitions in AUTHZ spec |
| Scope | Own company only |

### 4. Remove Members

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:manage` |
| Mechanism | Soft removal (membership deactivated) |
| Constraints | Cannot remove self, cannot remove last admin |
| Scope | Own company only |

### 5. View Pending Invitations

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:view` |
| Data Returned | Invitation ID, email, assigned role, sent date, status |
| Scope | Own company only |

### 6. Cancel Invitation

| Attribute | Value |
|-----------|-------|
| Actor | Admin, Super User |
| Permission | `users:invite` |
| Mechanism | Mark invitation as cancelled |
| Scope | Own company only |

---

## Explicit Non-Goals

The following are explicitly out of scope for this feature:

| Non-Goal | Reason |
|----------|--------|
| Cross-company user management | Tenant isolation requirement |
| Super user assignment via UI | Security-critical; requires direct DB |
| Permission customization per user | Role-based model only |
| User profile editing by admin | Self-service only (Profile Settings) |
| Password reset by admin | Self-service only (Auth flow) |
| Bulk user import | Future feature, separate governance |
| SSO/SAML configuration | Enterprise feature, separate governance |
| Two-factor enforcement | Security feature, separate governance |

---

## Roles Involved

### User (Self)

- Can view their own role
- Can request role changes (via Role Requests feature)
- Cannot manage other users
- Cannot invite users
- Cannot change their own role

### Admin

- Can view all company members
- Can invite new users
- Can assign roles to members
- Can remove members (except self, except last admin)
- Cannot assign super_user role
- Cannot manage users in other companies

### Super User

- All Admin capabilities
- Can view non-production companies
- Can switch company context
- Cannot assign super_user role via UI
- Platform-level audit logging applies

---

## Company Scoping Rules

### Rule 1: Membership Required

A user can only manage users in companies where they are an active member with appropriate permissions.

```sql
-- Enforced via RLS
company_id IN (
  SELECT company_id FROM company_members
  WHERE user_id = auth.uid()
  AND status = 'active'
)
```

### Rule 2: Active Company Context

The "active company" is determined by:
1. User's selected company (stored in session/local)
2. Validated against membership on each request

### Rule 3: No Cross-Company References

When inviting or managing users:
- Cannot reference users from other companies
- Cannot assign users to other companies
- Cannot view membership status in other companies

### Rule 4: Super User Exception

Super users can switch company context, but:
- Still operate within one company at a time
- All actions are scoped to the active company
- Company switches are audit logged

---

## Open Questions

| # | Question | Status |
|---|----------|--------|
| 1 | Should admins see invitation acceptance rate metrics? | Deferred |
| 2 | Should role changes require approval workflow? | Deferred to Role Requests |
| 3 | Should removed members be able to be re-invited? | Yes, as new invitation |
| 4 | Should there be a maximum member count per tier? | Business decision pending |

---

## Related Documents

| Document | Purpose |
|----------|---------|
| `AUTHZ_MANAGE_USERS.md` | Authorization rules |
| `UI_GOVERNANCE.md` | UI scope boundaries |
| `DEV_GOVERNANCE_CHECKLIST.md` | Implementation prerequisites |
