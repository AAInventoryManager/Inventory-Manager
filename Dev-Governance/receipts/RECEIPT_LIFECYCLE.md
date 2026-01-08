# Receipt Lifecycle Contract

## Purpose

This document defines the lifecycle states of receipts and the strict boundaries around inventory mutation.

---

## Lifecycle States

| State | Description |
|-------|-------------|
| `draft` | Receipt created from ingestion; awaiting user review |
| `blocked_by_plan` | User attempted action gated by subscription tier |
| `received` | User confirmed receipt; inventory updated |
| `voided` | Receipt cancelled after confirmation (if applicable) |

### State Diagram

```
                    ┌─────────────────┐
                    │     draft       │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              │              ▼
    ┌─────────────────┐      │    ┌─────────────────┐
    │ blocked_by_plan │      │    │    received     │
    └────────┬────────┘      │    └────────┬────────┘
             │               │             │
             │  (upgrade +   │             │ (if supported)
             │  confirmation)│             ▼
             └───────────────┘    ┌─────────────────┐
                                  │     voided      │
                                  └─────────────────┘
```

---

## State Transitions

### Allowed Transitions

| From | To | Trigger | Requirements |
|------|----|---------|--------------|
| `draft` | `received` | User confirms receipt | Explicit user action |
| `draft` | `blocked_by_plan` | Tier enforcement | Automatic on gated action attempt |
| `blocked_by_plan` | `received` | Upgrade + confirmation | Plan upgrade AND explicit user action |
| `received` | `voided` | User voids receipt | Explicit user action (if supported) |

### Prohibited Transitions

| Transition | Reason |
|------------|--------|
| `draft` → `received` (automatic) | User confirmation is mandatory |
| `blocked_by_plan` → `received` (automatic) | Upgrade does not auto-confirm |
| `voided` → any state | Voided is terminal |
| Any state → `draft` | Drafts are entry-only |

---

## Inventory Mutation Boundary

### The Rule

**Inventory quantities may change ONLY at:**

1. **Receive Inventory confirmation** — User explicitly confirms a receipt or PO
2. **Inventory Adjustment creation** — User explicitly creates an adjustment record

### What This Means

```
Receipt ingestion ──────────────────────────► NO inventory change
OCR/parsing ────────────────────────────────► NO inventory change
Draft receipt creation ─────────────────────► NO inventory change
Draft receipt editing ──────────────────────► NO inventory change
User clicks "Receive Inventory" ────────────► YES inventory change
User creates "Inventory Adjustment" ────────► YES inventory change
```

### Enforcement

The inventory mutation boundary must be enforced at:
- API layer (endpoints that modify `inventory.on_hand`)
- Database layer (triggers/constraints where applicable)
- UI layer (confirmation modals, not just button clicks)

---

## Draft Receipt Guarantees

### Always Preserved

| Guarantee | Rationale |
|-----------|-----------|
| Draft receipts are never auto-deleted | User may need historical reference |
| Raw attachments are always stored | Original source must be recoverable |
| Metadata is preserved even if parsing fails | Audit trail requirement |

### Never Assumed

| Assumption | Why Prohibited |
|------------|----------------|
| Draft means intent to receive | User may be reviewing, not acting |
| Old draft means abandoned | Users have varying workflows |
| Parsed data is correct | OCR is untrusted |

---

## Voided Receipts (If Applicable)

If void functionality is implemented:

| Requirement | Implementation |
|-------------|----------------|
| Void is explicit user action | Modal confirmation required |
| Void creates audit record | Inventory change must be traceable |
| Void does not delete data | Soft delete with reason |
| Voided items remain visible | For audit and reconciliation |

---

## Governance Checklist

- [ ] No silent inventory mutation
- [ ] Stable receipt address
- [ ] User confirmation required
- [ ] Tier gating without data loss
- [ ] OCR treated as advisory
- [ ] Slug is single source of truth
