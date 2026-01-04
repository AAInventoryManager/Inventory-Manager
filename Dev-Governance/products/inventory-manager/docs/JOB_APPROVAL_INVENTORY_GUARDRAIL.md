# Job Approval Inventory Guardrail

**Version:** 1.0
**Last Updated:** January 2026
**Status:** Active

---

## 1. Purpose

This document defines the authoritative behavior of the job approval inventory guardrail. The guardrail prevents jobs from being approved when inventory changes would cause the job to become unfulfillable.

---

## 2. Why "Any Inventory Change" Is Incorrect

### The Problem

The original implementation blocked job approval whenever ANY inventory change occurred between opening the job editor and clicking approve. This caused false positives in several legitimate scenarios:

| Scenario | Old Behavior | Correct Behavior |
|----------|--------------|------------------|
| User reseeds inventory to resolve shortage | BLOCKED | ALLOW |
| Shortage decreases (partial reseed) | BLOCKED | ALLOW |
| Unrelated item inventory changes | BLOCKED | ALLOW |
| Inventory increases on job items | BLOCKED | ALLOW |

### Business Impact

Blocking on "any change" created friction for users who:
- Intentionally reseeded inventory before approving a job
- Were working on jobs while other inventory operations occurred
- Had multi-user environments with concurrent inventory activity

---

## 3. Definition of Meaningful Regression

A **meaningful regression** occurs when:

```
wasFulfillable === true  AND  isNowFulfillable === false
```

Where:
- `wasFulfillable`: The job had zero shortfall when the job editor was opened (captured client-side and passed to the RPC)
- `isNowFulfillable`: The job has zero shortfall at approval time (computed server-side)

### Shortfall Calculation

For each BOM line:
```
available = on_hand - reserved
shortfall = max(0, qty_needed - available)
```

A job is **fulfillable** when:
```
total_shortfall === 0  (sum of all line shortfalls)
```

---

## 4. Approval-Time Algorithm

### Step 1: Fetch Current State
```javascript
1. Re-fetch CURRENT inventory for all job BOM item_ids
2. Fetch current reserved quantities for all approved/in_progress jobs
```

### Step 2: Compute Current Availability
```javascript
for each BOM line:
  available = on_hand - reserved
  shortfall = max(0, qty_planned - available)
```

### Step 3: Determine Fulfillability States
```javascript
isNowFulfillable = (current_total_shortfall === 0)
wasFulfillable = p_was_fulfillable  // captured at editor open and passed to RPC
```

### Step 4: Apply Guardrail (Server-Side)
```javascript
if (wasFulfillable && !isNowFulfillable) {
  // BLOCK: Job regressed from fulfillable to not fulfillable
  raise error: "Inventory changed during job approval"
  return;
}
// ALLOW: Either job was never fulfillable, or is still fulfillable
proceed with approval...
```

---

## 5. Concurrency Behavior

### Scenario: Two Users Competing for Same Inventory

```
Timeline:
T1: User A opens Job A (fulfillable, needs 4 of Item X)
T2: User B opens Job B (fulfillable, needs 4 of Item X)
T3: User B approves Job B → succeeds, reserves 4 of Item X
T4: User A approves Job A → BLOCKED (0 available, need 4)
```

### Backend Protection

The backend `approve_job` RPC uses `FOR UPDATE` row locking:
```sql
PERFORM 1
FROM public.inventory_items i
JOIN public.job_bom b ON b.item_id = i.id
WHERE b.job_id = p_job_id
FOR UPDATE;
```

This ensures:
- Atomic inventory checks at approval time
- No race conditions between concurrent approvals
- Deterministic blocking based on current state

---

## 6. Examples

### Example 1: Reseeding Resolves Shortage (ALLOWED)

```
Initial State:
- Item X: on_hand=2, reserved=0
- Job needs: 5 units

User opens job editor:
- wasFulfillable = false (shortfall = 3)

User reseeds inventory:
- Item X: on_hand=10, reserved=0

User clicks approve:
- isNowFulfillable = true (shortfall = 0)
- wasFulfillable = false

Decision: ALLOW (job was never fulfillable, now is)
```

### Example 2: Concurrent Reservation (BLOCKED)

```
Initial State:
- Item X: on_hand=5, reserved=0
- Job A needs: 4 units

User A opens job editor:
- wasFulfillable = true (available = 5, need 4)

User B approves Job B (needs 4 of Item X):
- Item X: on_hand=5, reserved=4

User A clicks approve:
- isNowFulfillable = false (available = 1, need 4)
- wasFulfillable = true

Decision: BLOCK (regression from fulfillable to not fulfillable)
```

### Example 3: Unrelated Item Change (ALLOWED)

```
Initial State:
- Item X: on_hand=10
- Item Y: on_hand=10
- Job needs: 5 of Item X

User opens job editor:
- wasFulfillable = true

Another user reduces Item Y to 0.

User clicks approve:
- isNowFulfillable = true (Item X unchanged)
- wasFulfillable = true

Decision: ALLOW (unrelated item change)
```

---

## 7. Testing Strategy

### Test Suite: `jobs_approval_inventory_consistency`

| Test | Scenario | Expected Result |
|------|----------|-----------------|
| TEST 1 | Reseed resolves shortage | Approval succeeds |
| TEST 2 | Inventory reduction causes regression | Approval blocked with `Insufficient inventory` |
| TEST 3 | Concurrent user conflict | Second approval blocked |
| TEST 4 | Unrelated inventory change | Approval succeeds |

### Test Location

```
/tests/integration/rpc/jobs.test.ts
```

### Test Requirements

- Tests run in isolation
- No reliance on UI state
- Assertions check approval result and error messages

---

## 8. Error Messages

### When Approval Is Blocked

**Title:** Inventory changed during job approval

**Message:** Inventory was reduced or reserved by another operation while you were editing this job, and it can no longer be fulfilled.

### Dev Mode Logging

When `DEV_MODE === true`, blocked approvals log:
```javascript
console.warn('[DEV] Approval blocked - fulfillability regression:', [
  { item_id, previous_shortage: 0, current_shortage }
]);
```

---

## 9. Related Documentation

- [Dev Standards](./dev-standards.md) - General development standards
- Backend RPC: `supabase/migrations/050_job_approval_guardrail.sql` - `approve_job` function
- Frontend Logic: `index.html` - `approveJob()` passes `p_was_fulfillable`

---

## Document History

- v1.0 (Jan 2026): Initial guardrail specification
