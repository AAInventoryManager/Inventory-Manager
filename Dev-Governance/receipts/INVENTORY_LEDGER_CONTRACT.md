# Inventory Ledger Contract

## Purpose

This document defines the strict boundaries around inventory mutation, ensuring that all inventory changes are explicit, auditable, and traceable to user actions.

---

## Inventory Mutation Sources

### Authorized Sources

Inventory on-hand may change **ONLY** via:

| Source | Description |
|--------|-------------|
| **Receiving Inventory** | Confirming a PO or receipt |
| **Inventory Adjustments** | Explicit adjustment record with reason |

### Source Details

#### Receiving Inventory

```
Purchase Order (confirmed)  ───► inventory.on_hand increases
Receipt (confirmed)         ───► inventory.on_hand increases
```

Requirements:
- User explicitly clicks confirm/receive
- System records who, when, what, and why
- Quantity changes are itemized

#### Inventory Adjustments

```
Positive Adjustment  ───► inventory.on_hand increases
Negative Adjustment  ───► inventory.on_hand decreases
```

Requirements:
- User creates explicit adjustment record
- Reason code or note required
- Full audit trail maintained

---

## Explicit Prohibition

### Receipt Ingestion

Receipt ingestion, OCR, parsing, and previews must **NEVER**:

| Prohibited Action | Why |
|-------------------|-----|
| Change inventory quantities | Ingestion is read-only |
| Allocate inventory | Allocation requires explicit user action |
| Affect job readiness directly | Job status derived from confirmed inventory |
| Create inventory records | Only confirmation creates records |
| Update existing inventory | Only adjustments/receiving update records |

### Automatic Processes

No background job, cron task, or automated process may:

| Prohibited | Reason |
|------------|--------|
| Reconcile inventory silently | User must review discrepancies |
| Auto-adjust based on patterns | Patterns may be wrong |
| Sync with external systems without confirmation | External data is untrusted |
| Apply "suggested" quantities | Suggestions require confirmation |

---

## Audit Expectations

### Traceability Requirement

Every inventory change must be explainable via one of:

| Source Document | Fields |
|-----------------|--------|
| **Receipt** | `receipt_id`, `confirmed_by`, `confirmed_at` |
| **Purchase Order** | `po_id`, `received_by`, `received_at` |
| **Adjustment** | `adjustment_id`, `created_by`, `reason`, `created_at` |
| **Job Actuals** | `job_id`, `line_id`, `actual_qty`, `recorded_by` |

### Query Guarantee

For any inventory item, it must be possible to:

```sql
-- Reconstruct current quantity from historical records
SELECT
  SUM(quantity_change) as computed_on_hand
FROM inventory_ledger
WHERE item_id = ?
GROUP BY item_id

-- Result must match inventory.on_hand
```

### Audit Record Requirements

| Field | Required | Purpose |
|-------|----------|---------|
| `item_id` | Yes | What changed |
| `quantity_change` | Yes | How much (+/-) |
| `source_type` | Yes | Receipt/PO/Adjustment/Job |
| `source_id` | Yes | Link to source document |
| `user_id` | Yes | Who caused the change |
| `timestamp` | Yes | When it happened |
| `reason` | For adjustments | Why it happened |

---

## Ledger Integrity Rules

### No Orphaned Changes

Every inventory change must link to a source document. Orphaned ledger entries are prohibited.

### No Silent Corrections

If inventory is incorrect:
- Create an explicit adjustment
- Document the reason
- Do not silently "fix" the number

### No Derived Mutations

Inventory changes must not result from:
- Cache invalidation
- View refreshes
- Background calculations
- External system syncs (without confirmation)

---

## Implementation Boundaries

### Database Layer

```sql
-- Inventory changes ONLY through controlled functions/procedures
-- Direct UPDATE on inventory.on_hand is prohibited in application code
-- Use: receive_inventory(), create_adjustment()
```

### API Layer

```
POST /api/inventory/receive    ──► Allowed (with confirmation)
POST /api/inventory/adjust     ──► Allowed (with reason)
POST /api/receipts/ingest      ──► Creates draft only
PUT  /api/inventory/:id        ──► Prohibited for on_hand changes
```

### Business Logic

```
receiveInventory(receipt, user)   ──► Changes inventory
createAdjustment(item, qty, user) ──► Changes inventory
ingestReceipt(email)              ──► NO inventory change
parseReceipt(attachment)          ──► NO inventory change
previewReceiving(draft)           ──► NO inventory change
```

---

## Exception Handling

### When Things Go Wrong

| Scenario | Response |
|----------|----------|
| OCR misreads quantity | User corrects in review, no auto-fix |
| Receipt has wrong items | User edits draft, no auto-correction |
| Duplicate receipt ingested | User resolves, system does not auto-dedupe inventory |
| System crash during receive | Transaction rolls back, user retries |

### No "Helpful" Automation

| Tempting Shortcut | Why Prohibited |
|-------------------|----------------|
| Auto-correct obvious errors | "Obvious" is subjective |
| Batch-confirm similar receipts | Each receipt needs review |
| Smart quantity suggestions | Suggestions ≠ confirmation |
| ML-based auto-receiving | ML confidence ≠ user intent |

---

## Governance Checklist

- [ ] No silent inventory mutation
- [ ] Stable receipt address
- [ ] User confirmation required
- [ ] Tier gating without data loss
- [ ] OCR treated as advisory
- [ ] Slug is single source of truth
