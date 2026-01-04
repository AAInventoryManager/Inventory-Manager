# Receiving Invariants

> Business rules that must always hold true for the Receiving domain.

## Receipt Invariants

### INV-RCV-001: Receipt Must Have Company
```
INVARIANT: receipt.company_id IS NOT NULL

Every receipt must belong to exactly one company for tenant isolation.
Enforced: Database NOT NULL constraint
```

### INV-RCV-002: Completed Receipt Immutable
```
INVARIANT: IF receipt.status IN ('completed', 'voided')
           THEN receipt header and lines are append-only and immutable

Once a receipt is completed, neither header fields nor line items can be
inserted, updated, or deleted. Only a void transition may add void metadata.
Exception: Void operation on completed receipts (Enterprise only).
Enforced: RLS policy + trigger
```

### INV-RCV-003: Receipt Number Unique Per Company
```
INVARIANT: UNIQUE(company_id, receipt_number)

Receipt numbers must be unique within a company.
Format: RCV-YYYYMMDD-XXXX (auto-generated)
Enforced: Database unique constraint
```

### INV-RCV-004: Non-Empty Receipt for Submission
```
INVARIANT: IF receipt.status != 'draft'
           THEN receipt.lines.count > 0

A receipt cannot be submitted without at least one line item.
Enforced: Transition function check
```

### INV-RCV-005: Multiple Receipts Per Purchase Order
```
INVARIANT: purchase_order_id may appear on multiple receipts

Partial receiving is supported by allowing multiple receipts per PO.
Enforced: No UNIQUE constraint + application validation
```

---

## Receipt Line Invariants

### INV-RCL-001: Line Belongs to Valid Receipt
```
INVARIANT: receipt_line.receipt_id references valid receipt
           AND receipt.company_id = line's item.company_id

Lines must reference a receipt in the same company as the item.
Enforced: Foreign key + RLS policy
```

### INV-RCL-002: Non-Negative Quantities
```
INVARIANT: received_qty >= 0
           AND rejected_qty >= 0
           AND expected_qty >= 0

All quantity fields must be non-negative. (received_qty == qty_received,
rejected_qty == qty_rejected)
Enforced: Database CHECK constraint
```

### INV-RCL-003: Received + Rejected <= Expected (Soft)
```
ADVISORY: received_qty + rejected_qty <= expected_qty

When receiving against a PO, total disposition should not exceed expected.
Over-receiving triggers a warning, not a hard block.
Enforced: Application-level warning
```

### INV-RCL-004: Rejection Requires Reason
```
INVARIANT: IF rejected_qty > 0
           THEN rejection_reason IS NOT NULL
           AND LENGTH(rejection_reason) > 0

Any rejected quantity must have an explanation.
Enforced: Application validation + trigger
```

### INV-RCL-005: Item Must Exist and Be Active
```
INVARIANT: receipt_line.item_id references item
           WHERE item.deleted_at IS NULL

Cannot receive against a deleted/trashed item.
Enforced: Foreign key + application check
```

---

## State Transition Invariants

### INV-TRN-001: Valid State Transitions Only
```
INVARIANT: State transitions follow defined state machine

Valid transitions:
  draft    → pending, completed (Professional only)
  pending  → completed, draft
  completed → voided (Enterprise only)
  voided   → (none)

Enforced: Transition validation function
```

### INV-TRN-002: Approval Segregation
```
INVARIANT: IF transition = 'approve'
           THEN approver != submitter (configurable)

Optional segregation of duties - approver cannot be the submitter.
Enforced: Application policy (configurable per company)
```

### INV-TRN-003: Void Requires Reason
```
INVARIANT: IF transition = 'void'
           THEN void_reason IS NOT NULL
           AND LENGTH(void_reason) >= 10

Voiding a completed receipt requires a substantive explanation.
Enforced: Application validation
```

---

## Inventory Impact Invariants

### INV-INV-001: Atomic Inventory Update
```
INVARIANT: Inventory updates from receipt completion are atomic

All line items update inventory in a single transaction.
Partial application is not allowed.
Enforced: Database transaction
```

### INV-INV-002: Void Has No Inventory Side Effects
```
INVARIANT: IF receipt is voided
           THEN inventory is unchanged by the void transition

Voiding a receipt does not reverse inventory changes. Corrections require a
separate corrective receipt or a manual adjustment outside Receiving.
Enforced: Transition validation + no inventory side effects on void
```

### INV-INV-003: Completion Deltas Are Non-Negative
```
INVARIANT: Inventory deltas applied on completion are non-negative

Receipt completion only increases on_hand and never reduces inventory.
Enforced: received_qty >= 0 validation
```

### INV-INV-004: Inventory Changes Only From Receipt Lines (Receiving)
```
INVARIANT: Within Receiving, item.quantity changes only when a receipt is completed
           AND only by applying line.received_qty

Inventory does not change from purchase order creation or edits.
Enforced: Triggered inventory adjustment + restricted write paths
```

---

## Audit Invariants

### INV-AUD-001: All Transitions Logged
```
INVARIANT: Every state transition creates an audit log entry

Fields logged: receipt_id, from_status, to_status, user_id, timestamp, reason
Enforced: Trigger on receipt status change
```

### INV-AUD-002: Inventory Adjustments Logged
```
INVARIANT: Every inventory quantity change creates action_metrics entry

Receiving approval and voids generate metrics records.
Enforced: Trigger on item quantity change
```

### INV-AUD-003: Receipt Events Logged
```
INVARIANT: receipt_created, receipt_completed, receipt_voided,
           receipt_line_received are recorded with required fields

All receipt lifecycle actions are auditable.
Enforced: Audit event emitter + database append-only log
```

### INV-AUD-004: Idempotent Receipt Processing
```
INVARIANT: Replaying a receipt completion does not double-apply inventory,
           and replays of void do not duplicate audit events

Receipt processing must be idempotent per receipt_id and transition.
Enforced: Idempotency keys + unique constraints on event dedupe
```

---

## Permission Invariants

### INV-PRM-001: Tier Gates Features
```
INVARIANT: Feature access respects tier limits

- Professional: Basic receiving
- Business: Approval workflow
- Enterprise: Void capability

Enforced: Permission check functions + RLS
```

### INV-PRM-002: Permission Required for Actions
```
INVARIANT: Each action requires specific permission

- receiving:view   → Read receipts
- receiving:create → Create new receipts
- receiving:edit   → Modify draft receipts
- receiving:approve → Approve/reject pending
- receiving:void   → Void completed receipts

Enforced: RLS policies + application checks
```

---

## Data Integrity Invariants

### INV-DAT-001: Soft Delete Preservation
```
INVARIANT: Receipts are never hard-deleted

Voided receipts remain in database for audit trail.
Enforced: No DELETE permission via RLS
```

### INV-DAT-002: Timestamp Consistency
```
INVARIANT: created_at <= submitted_at <= received_at <= voided_at

Timestamps must follow logical order.
Enforced: Application validation
```

### INV-DAT-003: Cost Preservation
```
INVARIANT: unit_cost on receipt line is immutable after completion

Historical cost at time of receipt must be preserved.
Enforced: Trigger preventing update on completed receipts
```

---

## Summary Table

| ID | Category | Enforcement | Severity |
|----|----------|-------------|----------|
| INV-RCV-001 | Receipt | Database | Critical |
| INV-RCV-002 | Receipt | RLS + Trigger | Critical |
| INV-RCV-003 | Receipt | Database | Critical |
| INV-RCV-004 | Receipt | Application | High |
| INV-RCV-005 | Receipt | App + DB | High |
| INV-RCL-001 | Line | FK + RLS | Critical |
| INV-RCL-002 | Line | Database | Critical |
| INV-RCL-003 | Line | Application | Advisory |
| INV-RCL-004 | Line | Application | High |
| INV-RCL-005 | Line | FK + App | High |
| INV-TRN-001 | Transition | Function | Critical |
| INV-TRN-002 | Transition | Application | Medium |
| INV-TRN-003 | Transition | Application | High |
| INV-INV-001 | Inventory | Transaction | Critical |
| INV-INV-002 | Inventory | Function | Critical |
| INV-INV-003 | Inventory | Application | Advisory |
| INV-INV-004 | Inventory | Trigger + RLS | Critical |
| INV-AUD-001 | Audit | Trigger | High |
| INV-AUD-002 | Audit | Trigger | High |
| INV-AUD-003 | Audit | App + DB | High |
| INV-AUD-004 | Audit | App + DB | Critical |
| INV-PRM-001 | Permission | RLS + App | Critical |
| INV-PRM-002 | Permission | RLS + App | Critical |
| INV-DAT-001 | Data | RLS | Critical |
| INV-DAT-002 | Data | Application | Medium |
| INV-DAT-003 | Data | Trigger | High |
