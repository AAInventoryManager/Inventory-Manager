# Subscription Gating Contract

## Purpose

This document defines how subscription tiers interact with receipt ingestion, ensuring that gating applies to **actions** but never to **data capture**.

---

## Core Principle: Visibility vs Capability

### The Rule

| Aspect | Tier Behavior |
|--------|---------------|
| **Visibility** | Never gated—all tiers see their data |
| **Capability** | May be gated—actions require appropriate tier |

### What This Means

```
Receipt address visible?     ──► YES, always (all tiers)
Draft receipts created?      ──► YES, always (all tiers)
Receipts viewable?           ──► YES, always (all tiers)
Attachments downloadable?    ──► Only on tiers with receipt storage, within retention window
Receiving inventory?         ──► MAY be gated by tier
Bulk operations?             ──► MAY be gated by tier
```

---

## Always Available (All Tiers)

| Feature | Rationale |
|---------|-----------|
| Receipt email address | Customers configure external systems |
| Receipt ingestion | Data capture must never be interrupted |
| Draft receipt viewing | Customer paid for this data |
| Receipt metadata + raw email text | Original text source for review |
| Receipt history | Audit trail is non-negotiable |

---

## Gated Actions

Actions that may require specific subscription tiers:

| Action | Gating Rationale |
|--------|------------------|
| Confirm & Receive Inventory | Core paid feature |
| Bulk receiving | Power user feature |
| Advanced parsing options | Premium feature |
| API access to receipts | Integration tier |
| Receipt attachment storage | Premium retention feature |

### Gating Behavior

When a user attempts a gated action:

1. **Inform** — Show clear message about tier requirement
2. **Preserve** — Keep all draft data intact
3. **Path** — Provide clear upgrade path
4. **No loss** — Never discard or hide data

---

## Prohibited Behaviors

### Email Handling

| Prohibited | Required |
|------------|----------|
| Bouncing receipt emails | Always accept and store |
| Rejecting based on tier | Always ingest regardless of tier |
| Rate limiting by tier | Ingest all, gate actions only |

### Address Management

| Prohibited | Required |
|------------|----------|
| Hiding receipt addresses | Always show address |
| Regenerating addresses on upgrade | Address is permanent |
| Different addresses per tier | One address per company |

### Data Handling

| Prohibited | Required |
|------------|----------|
| Discarding receipts due to plan | Always preserve |
| Deleting receipt records on downgrade | Receipt data survives tier changes |
| Expiring receipt records by tier | Receipt records are never deleted |

---

## Upgrade Behavior

### What Upgrade Unlocks

| Unlocked | Not Changed |
|----------|-------------|
| Previously gated actions | Receipt address (unchanged) |
| Bulk operations | Existing draft receipts (already exist) |
| Advanced features | Historical data (always accessible) |

### What Upgrade Does NOT Do

| Never | Reason |
|-------|--------|
| Auto-confirm pending receipts | User confirmation still required |
| Change receipt addresses | Stability guarantee |
| Backfill missing data | Data was already captured |
| Trigger automatic processing | User must initiate |

---

## Downgrade Behavior

### Data Preservation

| On Downgrade | Behavior |
|--------------|----------|
| Existing receipts | Preserved, remain viewable |
| Receipt address | Unchanged, still works |
| Ingestion pipeline | Still functional |
| Gated actions | Blocked until re-upgrade |
| Attachment storage | New attachments stop storing; existing files remain until retention expiry |

### Graceful Degradation

When a user downgrades:

1. All data remains accessible
2. Receipt address continues working
3. New receipts still get ingested
4. Only actions are gated, never visibility

---

## Implementation Requirements

### Database

- No `tier` column in receipt storage (tier is runtime check)
- No cascade deletes based on subscription status
- Attachment retention timestamps allowed; receipt records do not expire

### API

- Ingestion endpoints accept all valid receipts
- Action endpoints check tier at execution time
- Error responses include upgrade path, not rejections

### UI

- Receipt list shows all receipts regardless of tier
- Gated buttons show upgrade prompts, not hidden
- No "premium blur" on customer data
- Attachment areas show plan gating without hiding receipt metadata

---

## Governance Checklist

- [ ] No silent inventory mutation
- [ ] Stable receipt address
- [ ] User confirmation required
- [ ] Tier gating without data loss
- [ ] OCR treated as advisory
- [ ] Slug is single source of truth
