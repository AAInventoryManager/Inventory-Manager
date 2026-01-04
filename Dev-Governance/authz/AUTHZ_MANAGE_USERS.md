# Authorization: Manage Users & Role Assignment

> Defines authorization rules for company-scoped user management.

---

## Authorization Model

| Attribute | Value |
|-----------|-------|
| Model | Permission-based RBAC |
| Scope | Company-scoped |
| Enforcement | Backend (RLS + RPC) |
| Tier Requirement | Business, Enterprise |

---

## Permission Definitions

| Permission | Description | Default Roles |
|------------|-------------|---------------|
| `users:view` | View company member list | admin |
| `users:invite` | Send invitations to new users | admin |
| `users:manage` | Assign roles, remove members | admin |

---

## Who Can List Users

### Rule

Only users with `users:view` permission can list company members.

### Authorization Check

```sql
-- RLS Policy: company_members SELECT
CREATE POLICY "Users can view company members"
ON company_members FOR SELECT
USING (
  company_id = get_active_company_id()
  AND has_permission(auth.uid(), get_active_company_id(), 'users:view')
);
```

### Constraints

| Constraint | Enforcement |
|------------|-------------|
| Must be member of company | RLS `company_id` check |
| Must have `users:view` permission | RLS permission check |
| Cannot view other companies | RLS `company_id` filter |
| Tier must be Business+ | Permission only granted at Business+ |

---

## Who Can Invite Users

### Rule

Only users with `users:invite` permission can create invitations.

### Authorization Check

```sql
-- RPC: invite_user
CREATE FUNCTION invite_user(p_email TEXT, p_role TEXT)
RETURNS UUID AS $$
BEGIN
  -- Tier check
  IF NOT has_tier('business') THEN
    RAISE EXCEPTION 'Tier requirement not met';
  END IF;

  -- Permission check
  IF NOT has_permission(auth.uid(), get_active_company_id(), 'users:invite') THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  -- Role validation (cannot invite as super_user)
  IF p_role = 'super_user' THEN
    RAISE EXCEPTION 'Cannot assign super_user role';
  END IF;

  -- Create invitation...
END;
$$;
```

### Constraints

| Constraint | Enforcement |
|------------|-------------|
| Must have `users:invite` permission | RPC check |
| Cannot invite as `super_user` | RPC validation |
| Cannot invite existing members | RPC validation |
| Email must be valid format | RPC validation |
| Invitation scoped to active company | RPC uses `get_active_company_id()` |

---

## Who Can Assign Roles

### Rule

Only users with `users:manage` permission can change member roles.

### Authorization Check

```sql
-- RPC: update_member_role
CREATE FUNCTION update_member_role(p_member_id UUID, p_new_role TEXT)
RETURNS VOID AS $$
DECLARE
  v_target_company_id UUID;
  v_current_role TEXT;
BEGIN
  -- Get target member's company
  SELECT company_id, role INTO v_target_company_id, v_current_role
  FROM company_members WHERE id = p_member_id;

  -- Company scope check
  IF v_target_company_id != get_active_company_id() THEN
    RAISE EXCEPTION 'Cannot manage users in other companies';
  END IF;

  -- Permission check
  IF NOT has_permission(auth.uid(), v_target_company_id, 'users:manage') THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  -- Forbidden transition check
  IF p_new_role = 'super_user' THEN
    RAISE EXCEPTION 'Cannot assign super_user role';
  END IF;

  -- Self-modification check
  IF p_member_id = get_current_member_id() THEN
    RAISE EXCEPTION 'Cannot modify own role';
  END IF;

  -- Update role...
END;
$$;
```

### Constraints

| Constraint | Enforcement |
|------------|-------------|
| Must have `users:manage` permission | RPC check |
| Target must be in same company | RPC company check |
| Cannot assign `super_user` | RPC validation |
| Cannot modify own role | RPC self-check |

---

## Forbidden Role Transitions

The following role transitions are explicitly forbidden:

| From | To | Reason | Enforcement |
|------|----|--------|-------------|
| Any | `super_user` | Platform-level role, DB-only | RPC validation |
| `super_user` | Any | Cannot demote super users via UI | RPC validation |
| Self | Any | Cannot modify own role | RPC self-check |
| Last Admin | Non-admin | Company must retain one admin | RPC count check |

### Last Admin Protection

```sql
-- Before demoting an admin, verify at least one other admin exists
IF v_current_role = 'admin' AND p_new_role != 'admin' THEN
  IF (SELECT COUNT(*) FROM company_members
      WHERE company_id = v_target_company_id
      AND role = 'admin'
      AND status = 'active') <= 1 THEN
    RAISE EXCEPTION 'Cannot remove last admin';
  END IF;
END IF;
```

---

## Company Scoping Rules

### Rule 1: Active Company Binding

All operations are scoped to the user's active company:

```sql
get_active_company_id() -- Returns current company context
```

### Rule 2: Membership Validation

Before any operation, validate the actor is a member:

```sql
EXISTS (
  SELECT 1 FROM company_members
  WHERE user_id = auth.uid()
  AND company_id = get_active_company_id()
  AND status = 'active'
)
```

### Rule 3: Target Company Validation

When operating on a member, validate they belong to the same company:

```sql
-- Target member must be in actor's active company
target.company_id = get_active_company_id()
```

### Rule 4: No Cross-Company Joins

Queries must never join across company boundaries:

```sql
-- WRONG: Could leak cross-company data
SELECT * FROM company_members cm
JOIN users u ON cm.user_id = u.id;

-- RIGHT: Scoped to active company
SELECT * FROM company_members cm
JOIN users u ON cm.user_id = u.id
WHERE cm.company_id = get_active_company_id();
```

---

## Backend Enforcement Strategy

| Layer | Responsibility |
|-------|----------------|
| **RLS** | Company scoping, read access control |
| **RPC** | Write operations, complex validation |
| **Edge** | Rate limiting, request validation |

### RLS Policies Required

| Table | Policy | Check |
|-------|--------|-------|
| `company_members` | SELECT | `company_id` + `users:view` |
| `company_members` | UPDATE | Via RPC only (no direct) |
| `company_members` | DELETE | Via RPC only (no direct) |
| `invitations` | SELECT | `company_id` + `users:view` |
| `invitations` | INSERT | Via RPC only |
| `invitations` | UPDATE | Via RPC only |

### RPC Functions Required

| Function | Purpose | Permission |
|----------|---------|------------|
| `invite_user` | Create invitation | `users:invite` |
| `cancel_invitation` | Cancel pending invite | `users:invite` |
| `update_member_role` | Change member role | `users:manage` |
| `remove_member` | Deactivate membership | `users:manage` |
| `list_company_members` | Get member list | `users:view` |

---

## Test Requirements

### Unit Tests

| Test | Assertion |
|------|-----------|
| Permission check function | Returns correct boolean |
| Role validation | Rejects invalid roles |
| Forbidden transitions | Blocked at function level |

### Integration Tests

| Test | Assertion |
|------|-----------|
| Viewer cannot list members | RPC returns permission error |
| Admin can list members | RPC returns member list |
| Admin cannot assign super_user | RPC returns validation error |
| Admin cannot modify own role | RPC returns self-check error |
| Admin cannot manage other company | RPC returns scope error |
| Last admin cannot be demoted | RPC returns protection error |
| Invitation creates pending record | Database state correct |
| Role change updates member | Database state correct |
| Cross-company access blocked | RLS returns empty / error |

### Authorization Matrix Tests

```typescript
describe('Manage Users Authorization', () => {
  it('blocks viewer from listing members', async () => {
    const result = await asViewer.rpc('list_company_members');
    expect(result.error.code).toBe('PERMISSION_DENIED');
  });

  it('allows admin to list members', async () => {
    const result = await asAdmin.rpc('list_company_members');
    expect(result.data).toBeDefined();
    expect(result.data.length).toBeGreaterThan(0);
  });

  it('blocks admin from assigning super_user role', async () => {
    const result = await asAdmin.rpc('update_member_role', {
      p_member_id: memberId,
      p_new_role: 'super_user'
    });
    expect(result.error.message).toContain('Cannot assign super_user');
  });

  it('blocks cross-company member access', async () => {
    const result = await asAdminCompanyA.rpc('update_member_role', {
      p_member_id: memberInCompanyB,
      p_new_role: 'admin'
    });
    expect(result.error.code).toBe('SCOPE_VIOLATION');
  });
});
```

---

## Audit Requirements

| Action | Logged Fields |
|--------|---------------|
| `user.invited` | inviter_id, invitee_email, assigned_role |
| `user.role_changed` | actor_id, target_id, old_role, new_role |
| `user.removed` | actor_id, target_id, removal_reason |
| `invitation.cancelled` | actor_id, invitation_id |

---

## Summary Matrix

| Action | Permission | Tier | Self-Check | Company-Scoped |
|--------|------------|------|------------|----------------|
| List members | `users:view` | Business+ | No | Yes |
| Invite user | `users:invite` | Business+ | No | Yes |
| Change role | `users:manage` | Business+ | Blocked | Yes |
| Remove member | `users:manage` | Business+ | Blocked | Yes |
| Cancel invite | `users:invite` | Business+ | No | Yes |
