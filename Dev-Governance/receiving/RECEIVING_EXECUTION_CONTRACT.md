# Receiving Execution Contract

> Defines the execution semantics for receiving operations. Any implementation (UI, API, RPC) must comply with this contract.

---

## Operation: create-receipt

Creates a new receipt in DRAFT status, optionally linked to a purchase order.

### Inputs

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `company_id` | UUID | Yes | Tenant context (from session) |
| `purchase_order_id` | UUID | No | Link to originating PO |
| `supplier_id` | UUID | No | Supplier reference |
| `notes` | string | No | Free-form notes (max 2000 chars) |
| `lines` | array | No | Initial line items (can be added later) |

**Line item structure:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `item_id` | UUID | Yes | Inventory item reference |
| `po_line_id` | UUID | No | PO line reference (required if PO-linked) |
| `expected_qty` | integer | No | Expected quantity from PO |
| `received_qty` | integer | No | Actual received (default: 0) |
| `rejected_qty` | integer | No | Rejected quantity (default: 0) |
| `rejection_reason` | string | Conditional | Required if rejected_qty > 0 |
| `unit_cost` | decimal | No | Cost per unit |
| `lot_number` | string | No | Lot/batch identifier |
| `expiration_date` | date | No | Expiration for perishables |

### Preconditions

| # | Condition | Error Code |
|---|-----------|------------|
| P1 | User is authenticated | `ERR_UNAUTHORIZED` |
| P2 | User has `receiving:create` permission | `ERR_FORBIDDEN` |
| P3 | Company tier >= Professional | `ERR_TIER_REQUIRED` |
| P4 | `company_id` matches user's active company | `ERR_COMPANY_MISMATCH` |
| P5 | If `purchase_order_id` provided, PO exists and belongs to company | `ERR_PO_NOT_FOUND` |
| P6 | If `purchase_order_id` provided, PO status allows receiving | `ERR_PO_NOT_RECEIVABLE` |
| P7 | If `supplier_id` provided, supplier exists and belongs to company | `ERR_SUPPLIER_NOT_FOUND` |
| P8 | All `item_id` references exist, belong to company, and are not deleted | `ERR_ITEM_NOT_FOUND` |
| P9 | If `po_line_id` provided, it belongs to the specified PO | `ERR_PO_LINE_MISMATCH` |

### State Transitions

```
∅ → DRAFT
```

| Field | Value |
|-------|-------|
| `status` | `draft` |
| `receipt_number` | Auto-generated: `RCV-{YYYYMMDD}-{XXXX}` |
| `created_at` | Current timestamp |
| `updated_at` | Current timestamp |

### Inventory Side Effects

**None.** DRAFT receipts do not affect inventory quantities.

### Forbidden Actions

| Action | Reason |
|--------|--------|
| Creating with status other than DRAFT | Bypass of approval workflow |
| Linking to PO from different company | Tenant isolation violation |
| Adding lines for deleted items | Data integrity |
| Setting `received_at` or `received_by` | Reserved for post operation |

### Failure Modes

| Mode | Behavior | Rollback |
|------|----------|----------|
| Validation failure | Return error, no record created | N/A |
| Duplicate receipt_number | Retry with new sequence number | Auto-retry (3x) |
| Database constraint violation | Return error with constraint name | Full rollback |
| Partial line failure | Reject entire operation | Full rollback |

### Post-conditions

- Receipt exists with status = DRAFT
- Receipt number is unique within company
- All lines reference valid, active items
- Audit log entry created: `receipt.created`

---

## Operation: post-receipt

Posts a receipt to inventory, transitioning from DRAFT/PENDING to COMPLETED. This is the critical operation that affects inventory quantities.

### Inputs

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `receipt_id` | UUID | Yes | Receipt to post |
| `skip_approval` | boolean | No | Professional tier: skip PENDING state |

### Preconditions

| # | Condition | Error Code |
|---|-----------|------------|
| P1 | User is authenticated | `ERR_UNAUTHORIZED` |
| P2 | Receipt exists and belongs to user's company | `ERR_RECEIPT_NOT_FOUND` |
| P3 | Receipt status is DRAFT or PENDING | `ERR_INVALID_STATUS` |
| P4 | Receipt has at least one line item | `ERR_EMPTY_RECEIPT` |
| P5 | All line items have `received_qty >= 0` | `ERR_INVALID_QUANTITY` |
| P6 | All lines with `rejected_qty > 0` have `rejection_reason` | `ERR_REJECTION_REASON_REQUIRED` |
| P7 | All referenced items still exist and are not deleted | `ERR_ITEM_DELETED` |
| P8 | **If status = DRAFT:** User has `receiving:edit` permission | `ERR_FORBIDDEN` |
| P9 | **If status = PENDING:** User has `receiving:approve` permission | `ERR_FORBIDDEN` |
| P10 | **If status = PENDING + segregation enabled:** User ≠ `submitted_by` | `ERR_SELF_APPROVAL` |
| P11 | **If skip_approval = true:** Tier = Professional | `ERR_TIER_REQUIRED` |

### State Transitions

**Business/Enterprise Tier (two-step):**
```
DRAFT → PENDING → COMPLETED
```

**Professional Tier (direct post):**
```
DRAFT → COMPLETED
```

| Transition | Fields Updated |
|------------|----------------|
| DRAFT → PENDING | `status`, `submitted_at`, `submitted_by`, `updated_at` |
| PENDING → COMPLETED | `status`, `received_at`, `received_by`, `updated_at` |
| DRAFT → COMPLETED (Professional) | `status`, `received_at`, `received_by`, `updated_at` |

### Inventory Side Effects

**Executed atomically within a single transaction:**

```sql
FOR EACH line IN receipt.lines:
    UPDATE items
    SET quantity = quantity + line.received_qty,
        updated_at = now()
    WHERE id = line.item_id;

    -- Record in action_metrics
    INSERT INTO action_metrics (
        company_id, action_date, action_type,
        records_affected, quantity_added
    ) VALUES (
        receipt.company_id, CURRENT_DATE, 'receive',
        1, line.received_qty
    );
```

**Quantity changes:**
| Line Field | Inventory Effect |
|------------|------------------|
| `received_qty` | `item.quantity += received_qty` |
| `rejected_qty` | No inventory effect (documentation only) |

**PO updates (if linked):**
```sql
FOR EACH line IN receipt.lines WHERE po_line_id IS NOT NULL:
    UPDATE purchase_order_lines
    SET received_qty = received_qty + line.received_qty,
        updated_at = now()
    WHERE id = line.po_line_id;
```

### Forbidden Actions

| Action | Reason |
|--------|--------|
| Posting empty receipt | No meaningful inventory change |
| Posting with negative quantities | Receiving cannot reduce inventory |
| Skipping PENDING on Business/Enterprise | Tier workflow enforcement |
| Self-approval when segregation enabled | Separation of duties |
| Posting already COMPLETED receipt | Idempotency violation |
| Partial posting (subset of lines) | Atomic operation only |

### Failure Modes

| Mode | Behavior | Rollback |
|------|----------|----------|
| Item deleted mid-transaction | Abort with `ERR_ITEM_DELETED` | Full rollback |
| Constraint violation | Abort with constraint details | Full rollback |
| Deadlock on item row | Retry (3x), then fail | Full rollback |
| Connection lost mid-commit | Transaction rolled back by DB | Automatic |

### Post-conditions

- Receipt status = COMPLETED
- `received_at` and `received_by` are set
- All item quantities increased by `received_qty`
- All PO line `received_qty` updated (if linked)
- Action metrics recorded for the day
- Audit log entry created: `receipt.posted`
- Event emitted: `ReceiptApproved`, `InventoryAdjusted` (per line)

### Idempotency

**Not idempotent.** Calling post-receipt on an already COMPLETED receipt returns `ERR_INVALID_STATUS`. Clients must check status before calling.

---

## Operation: void-receipt

Reverses a COMPLETED receipt, removing its inventory impact. Enterprise tier only.

### Inputs

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `receipt_id` | UUID | Yes | Receipt to void |
| `void_reason` | string | Yes | Explanation (min 10 chars, max 500) |

### Preconditions

| # | Condition | Error Code |
|---|-----------|------------|
| P1 | User is authenticated | `ERR_UNAUTHORIZED` |
| P2 | Receipt exists and belongs to user's company | `ERR_RECEIPT_NOT_FOUND` |
| P3 | Receipt status is COMPLETED | `ERR_INVALID_STATUS` |
| P4 | User has `receiving:void` permission | `ERR_FORBIDDEN` |
| P5 | Company tier = Enterprise | `ERR_TIER_REQUIRED` |
| P6 | `void_reason` is provided and length >= 10 | `ERR_VOID_REASON_REQUIRED` |
| P7 | All referenced items still exist | `ERR_ITEM_NOT_FOUND` |
| P8 | **Advisory:** No item would go negative after void | `WARN_NEGATIVE_INVENTORY` |

### State Transitions

```
COMPLETED → VOIDED
```

| Field | Value |
|-------|-------|
| `status` | `voided` |
| `voided_at` | Current timestamp |
| `voided_by` | Current user ID |
| `void_reason` | Provided reason |
| `updated_at` | Current timestamp |

### Inventory Side Effects

**Executed atomically within a single transaction (exact reversal of post):**

```sql
FOR EACH line IN receipt.lines:
    UPDATE items
    SET quantity = quantity - line.received_qty,
        updated_at = now()
    WHERE id = line.item_id;

    -- Record negative adjustment in action_metrics
    INSERT INTO action_metrics (
        company_id, action_date, action_type,
        records_affected, quantity_removed
    ) VALUES (
        receipt.company_id, CURRENT_DATE, 'void_receive',
        1, line.received_qty
    );
```

**Quantity changes:**
| Line Field | Inventory Effect |
|------------|------------------|
| `received_qty` | `item.quantity -= received_qty` |

**PO updates (if linked):**
```sql
FOR EACH line IN receipt.lines WHERE po_line_id IS NOT NULL:
    UPDATE purchase_order_lines
    SET received_qty = received_qty - line.received_qty,
        updated_at = now()
    WHERE id = line.po_line_id;
```

### Forbidden Actions

| Action | Reason |
|--------|--------|
| Voiding non-COMPLETED receipt | Only posted receipts can be voided |
| Voiding without reason | Audit trail requirement |
| Voiding on non-Enterprise tier | Feature gating |
| Voiding twice | VOIDED is terminal state |
| Partial void (subset of lines) | Atomic operation only |

### Failure Modes

| Mode | Behavior | Rollback |
|------|----------|----------|
| Item deleted since posting | Abort with `ERR_ITEM_NOT_FOUND` | Full rollback |
| Would create negative inventory | Warn, require override flag | Block unless overridden |
| Constraint violation | Abort with constraint details | Full rollback |
| Deadlock on item row | Retry (3x), then fail | Full rollback |

### Negative Inventory Handling

By default, void-receipt will **warn but not block** if voiding would result in negative inventory. This allows correction of erroneous receipts even when items have been consumed.

| Company Setting | Behavior |
|-----------------|----------|
| `allow_negative_inventory = true` | Proceed with void |
| `allow_negative_inventory = false` | Require `force_void = true` input |

When `force_void = true` is required, the void reason must document why negative inventory is acceptable.

### Post-conditions

- Receipt status = VOIDED
- `voided_at`, `voided_by`, and `void_reason` are set
- All item quantities decreased by original `received_qty`
- All PO line `received_qty` decremented (if linked)
- Action metrics recorded for void
- Audit log entry created: `receipt.voided` with reason
- Event emitted: `ReceiptVoided`, `InventoryAdjusted` (per line, negative)
- Receipt remains in database (never hard-deleted)

### Idempotency

**Not idempotent.** Calling void-receipt on an already VOIDED receipt returns `ERR_INVALID_STATUS`.

---

## Transaction Boundaries

All three operations execute within a single database transaction:

```
BEGIN;
  -- Validate preconditions (SELECT ... FOR UPDATE on receipt)
  -- Acquire row locks on affected items
  -- Execute state transition
  -- Execute inventory side effects
  -- Record audit log
  -- Record action metrics
COMMIT;
```

Failure at any step triggers full rollback. No partial states are possible.

---

## Audit Requirements

| Operation | Audit Entry | Fields Captured |
|-----------|-------------|-----------------|
| create-receipt | `receipt.created` | receipt_id, user_id, company_id, po_id |
| post-receipt (submit) | `receipt.submitted` | receipt_id, user_id, line_count |
| post-receipt (approve) | `receipt.posted` | receipt_id, user_id, total_qty_received |
| void-receipt | `receipt.voided` | receipt_id, user_id, void_reason, total_qty_reversed |

All audit entries include timestamp, IP address (if available), and user agent.

---

## Event Emissions

| Operation | Events |
|-----------|--------|
| create-receipt | `ReceiptCreated` |
| post-receipt (submit) | `ReceiptSubmitted` |
| post-receipt (approve) | `ReceiptApproved`, `InventoryAdjusted[]` |
| void-receipt | `ReceiptVoided`, `InventoryAdjusted[]` |

Events are emitted **after** transaction commit. Failure to emit does not roll back the transaction (eventual consistency for downstream consumers).

---

## Summary Matrix

| Aspect | create-receipt | post-receipt | void-receipt |
|--------|----------------|--------------|--------------|
| Min Tier | Professional | Professional | Enterprise |
| Permission | `receiving:create` | `receiving:edit` / `receiving:approve` | `receiving:void` |
| Affects Inventory | No | Yes (+) | Yes (-) |
| Reversible | Yes (delete draft) | Yes (void) | No (terminal) |
| Idempotent | No | No | No |
| Requires Reason | No | No | Yes |
