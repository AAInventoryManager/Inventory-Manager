# UI Governance

> Defines scope boundaries and authorization rules for user interface components.

---

## Core Principle

**The UI is a presentation layer, not an authorization layer.**

All authorization decisions must be enforced by the backend. The UI may hide or disable controls for user experience, but it must never be the sole enforcement mechanism.

---

## Scope Definitions

### Self-Scoped UI

**Definition:** UI that allows users to manage only their own data.

**Example:** Profile Settings

| Capability | Scope | Authorization |
|------------|-------|---------------|
| View own profile | Self | Authenticated |
| Update own email | Self | Authenticated |
| Change own password | Self | Authenticated |
| Update own preferences | Self | Authenticated |
| View own role | Self | Authenticated |

**Constraints:**
- User can only see and modify their own record
- No visibility into other users' data
- No ability to affect other users' permissions
- Backend enforces `user_id = auth.uid()`

---

### Company-Scoped UI

**Definition:** UI that allows authorized users to manage data for their entire company.

**Example:** Manage Users, Role Assignment

| Capability | Scope | Authorization |
|------------|-------|---------------|
| List company members | Company | `users:view` permission |
| Invite new users | Company | `users:invite` permission |
| Assign roles | Company | `users:manage` permission |
| Remove members | Company | `users:manage` permission |

**Constraints:**
- User can only see members of their own company
- Actions affect other users within the same company
- Backend enforces `company_id` scoping via RLS
- Elevated permissions required for management actions

---

### Platform-Scoped UI

**Definition:** UI that allows super users to manage data across all companies.

**Example:** Company Switcher, Platform Metrics

| Capability | Scope | Authorization |
|------------|-------|---------------|
| View all companies | Platform | Super user only |
| Switch company context | Platform | Super user only |
| View platform metrics | Platform | Super user only |

**Constraints:**
- Only super users can access
- Explicit audit logging required
- UI must display environment indicators

---

## Forbidden Cross-Scope Actions

The following are explicitly forbidden:

| Action | Violation |
|--------|-----------|
| Profile UI modifying another user's data | Self-scope breach |
| Profile UI assigning roles | Scope escalation |
| Company UI accessing other companies | Tenant isolation breach |
| Any UI bypassing backend auth | Security violation |

---

## UI Authorization Rules

### Rule 1: Backend is Authoritative

```
UI disabled state != Authorization
UI hidden element != Authorization
Only backend RLS/RPC checks = Authorization
```

The UI may disable a button when a user lacks permission, but the backend must independently reject unauthorized requests.

### Rule 2: No Permission Inference

The UI must not infer permissions from other permissions. Each capability requires explicit permission check.

```
Wrong: "User can edit items, so they can probably delete them"
Right: "Check items:delete permission explicitly"
```

### Rule 3: Scope Boundaries are Hard

A self-scoped UI component must never:
- Accept a `user_id` parameter for other users
- Display data about other users
- Trigger actions affecting other users

A company-scoped UI component must never:
- Accept a `company_id` parameter for other companies
- Display data from other companies
- Trigger actions affecting other companies

### Rule 4: Audit Sensitive Actions

Any action in company-scoped or platform-scoped UI that modifies authorization state must be logged:
- Role assignments
- Permission changes
- Member additions/removals
- Invitations

---

## UI Component Classification

| Component | Scope | Location | Gate |
|-----------|-------|----------|------|
| Profile Settings | Self | Profile Modal | Authenticated |
| Manage Users | Company | User Management Modal | `users:view` + Business tier |
| Invite Users | Company | Invite Modal | `users:invite` + Business tier |
| Role Manager | Company | Role Modal | Super user only |
| Company Switcher | Platform | Header | Super user only |

---

## Implementation Checklist

When building UI that involves authorization:

- [ ] Identify scope (self / company / platform)
- [ ] Document in `UI_GOVERNANCE.md`
- [ ] Verify backend enforcement exists
- [ ] Add permission check in UI (for UX only)
- [ ] Ensure backend rejects unauthorized requests
- [ ] Add integration tests for authorization
- [ ] Verify no cross-scope data leakage

---

## Enforcement

- UI code reviews must verify scope boundaries
- Integration tests must verify backend rejects unauthorized UI requests
- Any UI that accepts scope parameters (user_id, company_id) requires explicit authorization documentation
