# Receipt State Machine

> Defines valid states and transitions for the Receipt aggregate.

## State Diagram

```
                                    ┌──────────────┐
                                    │              │
                    ┌───────────────│    VOIDED    │
                    │               │              │
                    │               └──────────────┘
                    │                      ▲
                    │                      │ void (Enterprise only)
                    │                      │
┌──────────┐    submit    ┌───────────┐  approve  ┌───────────┐
│          │─────────────▶│           │──────────▶│           │
│  DRAFT   │              │  PENDING  │           │ COMPLETED │
│          │◀─────────────│           │           │           │
└──────────┘    reject    └───────────┘           └───────────┘
     ▲                          │
     │                          │
     └──────────────────────────┘
             (edit while pending returns to draft)
```

## Inventory Mutation Rule
Inventory quantities are mutated ONLY when a receipt transitions to `completed`.

## States

### DRAFT
Initial state when a receipt is created.

| Property | Value |
|----------|-------|
| Editable | Yes |
| Lines modifiable | Yes |
| Inventory affected | No |
| Can delete | Yes |

**Allowed transitions:**
- `submit` → PENDING (requires at least one line item)

---

### PENDING
Receipt submitted and awaiting approval. In accounting terms: **validated but not posted**—quantities are locked but inventory has not been affected.

| Property | Value |
|----------|-------|
| Editable | No (must reject first) |
| Lines modifiable | No |
| Inventory affected | No |
| Can delete | No |

**Allowed transitions:**
- `approve` → COMPLETED (applies inventory adjustments)
- `reject` → DRAFT (returns for editing)

---

### COMPLETED
Receipt approved and inventory updated. In accounting terms: **posted**—inventory quantities have been adjusted and the transaction is recorded.

| Property | Value |
|----------|-------|
| Editable | No |
| Lines modifiable | No |
| Inventory affected | Yes (quantities applied) |
| Can delete | No |

**Allowed transitions:**
- `void` → VOIDED (Enterprise only)

---

### VOIDED
Completed receipt that has been marked void.

| Property | Value |
|----------|-------|
| Editable | No |
| Lines modifiable | No |
| Inventory affected | No (no additional changes) |
| Can delete | No |

**Allowed transitions:**
- None (terminal state)

---

## Forbidden Transitions
Only the transitions explicitly listed in this document are allowed; all others are forbidden.

## Transition Rules

### submit
```
Preconditions:
  - Current state = DRAFT
  - receipt.lines.length > 0
  - All lines have received_qty >= 0
  - User has receiving:edit permission

Postconditions:
  - State = PENDING
  - submitted_at = now()
  - submitted_by = current_user

Side effects:
  - Emit ReceiptSubmitted event
  - Notify approvers (if configured)
```

### approve
```
Preconditions:
  - Current state = PENDING
  - User has receiving:approve permission
  - User != submitted_by (optional: prevent self-approval)

Postconditions:
  - State = COMPLETED
  - received_at = now()
  - received_by = current_user

Side effects:
  - For each line: item.quantity += received_qty
  - Emit ReceiptApproved event
  - Emit InventoryAdjusted event per line
  - Update PO line received quantities (if linked)
```

### reject
```
Preconditions:
  - Current state = PENDING
  - User has receiving:approve permission

Postconditions:
  - State = DRAFT
  - rejection_reason = provided reason
  - rejected_at = now()
  - rejected_by = current_user

Side effects:
  - Emit ReceiptRejected event
  - Notify submitter
```

### void
```
Preconditions:
  - Current state = COMPLETED
  - User has receiving:void permission
  - Company tier = Enterprise
  - void_reason provided

Postconditions:
  - State = VOIDED
  - voided_at = now()
  - voided_by = current_user
  - void_reason = provided reason

Side effects:
  - Emit ReceiptVoided event
  - Create audit log entry with reason
  - No inventory changes; corrections require a separate corrective receipt or a manual adjustment outside Receiving
```

---

## Idempotency
- Repeated transition requests to the current state must be safe no-ops.
- Duplicate completion requests must not double-apply inventory changes.
- Retries for submit/approve/void must either succeed once or return a stable validation error with no side effects.

## Tier-Based Workflow Variations

### Professional Tier
Simplified flow without approval step:

```
┌──────────┐   complete   ┌───────────┐
│  DRAFT   │─────────────▶│ COMPLETED │
└──────────┘              └───────────┘
```

- No PENDING state
- No approval required
- `complete` transition directly applies inventory
- No void capability

### Business Tier
Full approval workflow (diagram above) without void.

### Enterprise Tier
Full workflow including void capability.

---

## Database Enum

```sql
CREATE TYPE receipt_status AS ENUM (
  'draft',
  'pending',
  'completed',
  'voided'
);
```

## Validation Functions

```sql
-- Validate state transition
CREATE FUNCTION validate_receipt_transition(
  current_status receipt_status,
  new_status receipt_status,
  tier text
) RETURNS boolean AS $$
BEGIN
  RETURN CASE
    -- From DRAFT
    WHEN current_status = 'draft' AND new_status = 'pending' THEN true
    WHEN current_status = 'draft' AND new_status = 'completed'
      AND tier = 'professional' THEN true

    -- From PENDING
    WHEN current_status = 'pending' AND new_status = 'completed' THEN true
    WHEN current_status = 'pending' AND new_status = 'draft' THEN true

    -- From COMPLETED
    WHEN current_status = 'completed' AND new_status = 'voided'
      AND tier = 'enterprise' THEN true

    ELSE false
  END;
END;
$$ LANGUAGE plpgsql;
```
