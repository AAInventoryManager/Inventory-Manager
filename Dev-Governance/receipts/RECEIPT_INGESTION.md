# Receipt Ingestion Contract

## Purpose

Receipt ingestion provides an external input mechanism (email, PDF, image) to **prepare** inventory receiving—never to **execute** it.

The ingestion pipeline exists solely to:
- Capture incoming receipt documents
- Extract text and data for user review
- Stage draft receipts for explicit confirmation

Receipt ingestion is a **read-only** operation with respect to inventory.

---

## Receipt Ingestion Address Contract

### Canonical Format

```
receipts+<company_slug>@inbound.inventorymanager.modulus-software.com
```

### Address Rules

| Rule | Rationale |
|------|-----------|
| Derived from `company.slug` | Single source of truth |
| Never stored as mutable data | Prevents desync |
| Never regenerated | Customer workflow stability |
| Stable for life of company | External systems depend on it |
| Exists regardless of subscription tier | Tier gates actions, not addresses |

### Examples

| Company Slug | Receipt Address |
|--------------|-----------------|
| `acme-corp` | `receipts+acme-corp@inbound.inventorymanager.modulus-software.com` |
| `smiths-welding` | `receipts+smiths-welding@inbound.inventorymanager.modulus-software.com` |

---

## Inbound Email Pipeline

```
Email
 │
 ▼
SendGrid Inbound Parse
 │
 ▼
Signature Verification
 │
 ▼
Company Resolution (slug extraction from plus-address)
 │
 ▼
Text Extraction (HTML → PDF → OCR → text)
 │
 ▼
Draft Receipt (created, never auto-confirmed)
 │
 ▼
User Review (required)
 │
 ▼
Explicit Receive Inventory (user action)
```

### Pipeline Guarantees

1. **Company resolution** uses only the plus-addressed slug
2. **Text extraction** is advisory—failures do not reject receipts
3. **Draft receipts** are always created, regardless of extraction success
4. **User review** is mandatory before any inventory impact

---

## Security Guarantees

| Guarantee | Implementation |
|-----------|----------------|
| No inbox access | Inbound-only; we receive, never fetch |
| No API key auth for inbound | Webhook-based, not credential-based |
| Webhook signature verification | SendGrid signature required |
| Receipt content preserved | Email body stored; attachments stored per retention policy |

### What We Never Do

- Poll external mail servers
- Store mail server credentials
- Accept unsigned webhook payloads
- Expose inbound endpoints without verification

---

## OCR & Parsing Rules

### OCR Classification

**OCR output is untrusted input.**

All parsed data from receipts must be treated as:
- Potentially incorrect
- Potentially incomplete
- Potentially malicious (sanitize before display)

### Parsing Behavior

| Scenario | Behavior |
|----------|----------|
| OCR succeeds | Populate draft fields for review |
| OCR fails | Create draft with email text; attachments stored if retention allows |
| Fields missing | Acceptable—user completes manually |
| Fields ambiguous | Present options, never guess |

Attachment OCR/parsing runs only when attachment storage is enabled for the tier.

### Mandatory Confirmation

No parsed data may affect inventory or system state until explicitly confirmed by an authorized user.

### Vendor-Specific Parsing

The parser includes vendor-specific rules to handle different receipt formats. See:

| Vendor | Documentation |
|--------|---------------|
| Lowe's | [parsers/LOWES_PARSER.md](parsers/LOWES_PARSER.md) |

When adding support for new vendors:
1. Document format quirks in a dedicated parser file
2. Add exclusion patterns for vendor-specific noise
3. Test with real receipt data
4. Update the table above

---

## Attachment Storage & Retention

Receipt attachments are stored only for tiers with receipt storage enabled. Ingestion never fails if attachments are not stored.

### Retention Policy

| Tier | Attachment Retention |
|------|----------------------|
| starter | 0 days (no attachment storage) |
| professional | 365 days |
| business | 365 days |
| enterprise | 7 years |

### Storage Providers

Attachment storage may use:
- Supabase Storage (default)
- External storage provider (configured via environment)

### Manual Cleanup

Admins can delete stored attachments at any time. Deleting storage never deletes the receipt record.

---

## Non-Goals

Receipt ingestion must **NOT**:

| Prohibited Action | Reason |
|-------------------|--------|
| Auto-receive inventory | Violates explicit confirmation requirement |
| Auto-create purchase orders | Business logic requires user intent |
| Auto-approve jobs | Job approval is a separate workflow |
| Guess intent | Ambiguity must surface to user |
| Modify inventory quantities | Ingestion is read-only |
| Match receipts to POs automatically | Matching requires user verification |
| Send auto-replies | No outbound email without user action |

---

## Governance Checklist

- [ ] No silent inventory mutation
- [ ] Stable receipt address
- [ ] User confirmation required
- [ ] Tier gating without data loss
- [ ] OCR treated as advisory
- [ ] Slug is single source of truth
