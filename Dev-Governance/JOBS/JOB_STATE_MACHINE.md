# Job State Machine

## Purpose
This document defines the authoritative lifecycle and readiness semantics
for Jobs in Inventory Manager.

Job state must always reflect material reality and inventory availability.

---

## Job States

### Draft
A job is Draft when:
- It has been created but has no Bill of Materials (BOM), OR
- One or more BOM items has a material shortfall, OR
- Materials have been removed or quantities reduced to zero

Draft jobs are not eligible for execution.

---

### Ready
A job is Ready when ALL of the following are true:
- At least one BOM line exists
- Every BOM item has sufficient available inventory
- No material shortfalls exist

Ready is a DERIVED state.
Users may not manually set a job to Ready.

---

### Active
A job is Active when:
- The job has been explicitly approved or started
- Execution has begun

Material changes after Active may still affect execution,
but do not revert state automatically.

---

### Completed
A job is Completed when:
- Execution is finished
- Inventory consumption has been finalized
- This is a terminal state (except via explicit Reopen flow)

---

## Readiness Derivation Rules

Readiness is computed exclusively from the Materials domain.

Pseudocode:

```
IF materials.count === 0:
  state = Draft
ELSE IF any(material.shortfall > 0):
  state = Draft
ELSE:
  state = Ready
```

This evaluation must run when:
- Materials are added
- Materials are removed
- Material quantities change
- Inventory availability changes

---

## Automatic State Demotion

The system MUST automatically demote a job from Ready → Draft when:
- A BOM line is removed
- A BOM quantity is reduced to zero
- Inventory changes introduce a shortfall

This is correctness, not punishment.

---

## State Explanation Notes (Lightweight)

Jobs MAY store a lightweight, append-only explanation of state changes
(e.g., Ready → Draft) for user clarity.

This is not a full audit log.

Example payload:
```json
{
  "at": "timestamp",
  "from": "Ready",
  "to": "Draft",
  "reason": "Materials removed or shortage detected"
}
```

Storage may be implemented as a capped JSON array on the jobs record.

---

## Explicit Non-Goals

- Users cannot manually toggle readiness
- No "Mark Ready" button may exist
- Readiness must not be computed from job metadata
- Readiness must not be overridden by UI actions

---

## Authoritative Rule

**Job readiness is computed from the Bill of Materials and inventory availability; it is not manually set.**

Any implementation violating this rule is incorrect.

End.
