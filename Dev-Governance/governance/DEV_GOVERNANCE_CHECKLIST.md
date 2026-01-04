# Dev Governance Checklist

> Mandatory evaluation rules for all feature development and authorization changes.

---

## Purpose

This checklist ensures that all new features, authorization changes, and scope modifications are properly documented before implementation begins. Governance documentation is not optional—it is a prerequisite for development.

**No implementation shall proceed without completed governance artifacts.**

---

## Mandatory Evaluation Rules

Before writing any runtime code, the following must be true:

### 1. Feature Documentation

- [ ] Feature specification exists in `/features/FEATURE_<NAME>.md`
- [ ] Problem statement is clearly defined
- [ ] Scope boundaries are explicitly documented
- [ ] Non-goals are listed to prevent scope creep
- [ ] Roles and permissions are identified

### 2. Authorization Documentation

- [ ] Authorization rules exist in `/authz/AUTHZ_<NAME>.md`
- [ ] All permission checks are explicitly defined
- [ ] Company/tenant scoping rules are documented
- [ ] Forbidden actions are enumerated
- [ ] Backend enforcement strategy is specified (RLS / RPC / Edge)
- [ ] Test requirements are documented

### 3. UI Governance (if applicable)

- [ ] UI scope boundaries are defined in `UI_GOVERNANCE.md`
- [ ] Self-scoped vs company-scoped actions are distinguished
- [ ] UI cannot bypass backend authorization (documented)
- [ ] No cross-scope actions are permitted

### 4. Schema Changes (if applicable)

- [ ] Schema definition exists in `/receiving/` or relevant domain folder
- [ ] Required fields are documented
- [ ] Write-once fields are identified
- [ ] Foreign key relationships are specified
- [ ] Invariants are documented

### 5. Execution Contract (if applicable)

- [ ] Operations are defined with inputs, preconditions, postconditions
- [ ] State transitions are documented
- [ ] Side effects are enumerated
- [ ] Failure modes are specified

---

## Blocking Rules

The following conditions **block** any implementation work:

| Condition | Consequence |
|-----------|-------------|
| Missing feature spec | Cannot begin UI or backend work |
| Missing authz spec | Cannot implement permission checks |
| Undefined scope boundaries | Cannot determine what to build |
| Missing enforcement strategy | Cannot implement security layer |
| No test requirements | Cannot verify authorization correctness |

---

## Governance Review Trigger

A governance review is required when:

1. **New Feature** — Any user-facing capability not previously documented
2. **Authorization Change** — Any modification to who can do what
3. **Scope Change** — Any expansion of existing feature boundaries
4. **Role Change** — Any new role or permission addition
5. **Data Model Change** — Any new entity or relationship

---

## Checklist for New Feature

```markdown
## Governance Checklist: [Feature Name]

### Documentation
- [ ] FEATURE_<NAME>.md created
- [ ] AUTHZ_<NAME>.md created (if authorization involved)
- [ ] UI_GOVERNANCE.md updated (if UI changes)
- [ ] Schema documented (if new entities)

### Authorization
- [ ] Permission matrix defined
- [ ] Company scoping rules defined
- [ ] Forbidden transitions enumerated
- [ ] Backend enforcement specified

### Testing
- [ ] Authorization test cases documented
- [ ] Edge cases identified
- [ ] Negative test cases required

### Review
- [ ] Self-review completed
- [ ] Governance artifacts committed
- [ ] Ready for implementation
```

---

## Enforcement

- AI assistants (Codex, Claude, etc.) must evaluate this checklist before generating implementation code
- Pull requests without governance artifacts will be rejected
- Governance documentation must be committed before or alongside implementation

---

## Document Locations

| Type | Path |
|------|------|
| Feature Specs | `/features/FEATURE_<NAME>.md` |
| Authorization | `/authz/AUTHZ_<NAME>.md` |
| UI Governance | `/governance/UI_GOVERNANCE.md` |
| Domain Schemas | `/<domain>/<DOMAIN>_SCHEMA.yaml` |
| Execution Contracts | `/<domain>/<DOMAIN>_EXECUTION_CONTRACT.md` |
| Invariants | `/<domain>/<DOMAIN>_INVARIANTS.md` |
