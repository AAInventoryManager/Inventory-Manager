# Lowe's Receipt Parser Rules

## Overview

This document describes the parsing rules specific to Lowe's Home Improvement receipt emails. These rules were developed through iterative testing against real Lowe's receipt data.

---

## Email Format

Lowe's receipts arrive via forwarded email from:
```
From: Lowe's Home Improvement <do-not-reply@receipt.lowes.com>
Subject: Your Lowe's Purchase Receipt
```

The email body contains HTML entities that must be decoded (`&lt;`, `&gt;`, `&nbsp;`, `&amp;`).

---

## Data Structure

### Header Section
```
LOWE'S HOME CENTERS, LLC
2150 Minton RD.
Melbourne , FL 32904
(321) 953-2880

Transaction # : 42381997
Order # : 200696365251417328
Order Date : 12/31/25 13:04:10
```

### Totals Section (appears BEFORE line items)
```
Invoice 89357 Subtotal
$ 51.84
...
Subtotal
$ 51.84
Total Tax
$ 3.63
Total
$ 55.47
```

**Key Insight**: Lowe's places totals BEFORE line items, which is atypical. The parser must scan the entire document, not stop at the first totals indicator.

### Line Items Section
```
Item                          <- Table header (exclude)
Price                         <- Table header (exclude)
PROPANE TANK EXCHANGE-BLU     <- Product description
$ 43.96                       <- Line total
Item #: 7384                  <- SKU
2 @ 21.98                     <- Quantity @ unit price
```

Multi-line format per item:
1. **Description** - Product name (all caps, may include size/variant)
2. **Price** - Line total prefixed with `$`
3. **Item #** - SKU number (captured as `sku` field)
4. **Quantity** - Format: `N @ unit_price`

Optional discount lines may appear:
```
3.88 Discount Ea -0.39        <- Exclude from parsing
```

---

## Parsing Rules

### 1. HTML Entity Decoding
| Entity | Decoded |
|--------|---------|
| `&nbsp;` | space |
| `&lt;` | `<` |
| `&gt;` | `>` |
| `&amp;` | `&` |
| `&quot;` | `"` |
| `&#NNN;` | character |

### 2. Vendor Name Extraction
- Source: `From:` line in forwarded email header
- Clean: Remove `<email@domain>` brackets and email addresses
- Result: "Lowe's Home Improvement"

### 3. Date Extraction
- Source: `Order Date :` line
- Format: `MM/DD/YY HH:MM:SS`
- Also check: `Date:` line in forwarded header (full date format)

### 4. Totals Extraction (Multi-line)
Labels and values appear on **separate lines**:
```
Total Tax
$ 3.63
```

Parser behavior:
1. Find label line (e.g., "Total Tax")
2. Check if label is alone on line
3. Look at next line for `$ N.NN` pattern
4. Extract numeric value

**Exclusions for "Total"**:
- `total savings` / `savings total`
- `subtotal`
- `total tax` / `tax total`

### 5. Line Item Extraction

#### Table Headers (Exclude)
Single-word lines that are column headers:
- `Item`, `Price`, `Qty`, `Quantity`, `Description`, `Amount`, `Unit`, `Total`, `SKU`

#### Product Detection
A line is a valid product description if:
- Length: 2-160 characters
- Contains at least 2 letters
- Letter count > digit count * 1.2
- Not excluded by keywords

#### SKU Extraction
Pattern: `Item #: NNNNNN` or `Item# NNNNNN`
- Captured in `sku` field of line item
- Line itself is excluded from product list

#### Quantity Extraction
Pattern: `N @ unit_price`
- Appears 1-3 lines after price line
- If not found, defaults to qty=1

#### Price Line
Pattern: `$ NN.NN` on its own line
- Must appear within 4 lines of description
- Becomes `line_total`

### 6. Exclusion Patterns

| Category | Patterns |
|----------|----------|
| **Payment** | payment, paid, cash, card, visa, mastercard, amex, debit, credit |
| **Auth** | auth, authtime, authcd, refid, approval |
| **Balance** | balance, card transaction, remaining, beginning |
| **Summary** | subtotal, tax, total, amount due, invoice, receipt, order |
| **Discount** | discount (anywhere in line) |
| **Rewards** | mylowe, rewards, points, survey, feedback |
| **Location** | store #, City ST ZIP, City, ST |
| **Dates** | Month DD YYYY, MM/DD/YYYY |
| **Auth Codes** | 6-digit numbers alone on line |

---

## Sample Parsed Output

**Input**: Lowe's receipt email (forwarded)

**Output**:
```json
{
  "vendor_name": "Lowe's Home Improvement",
  "receipt_date": "2025-12-31",
  "subtotal": 51.84,
  "tax": 3.63,
  "total": 55.47,
  "parsed_line_items": [
    {
      "description": "PROPANE TANK EXCHANGE-BLU",
      "sku": "7384",
      "qty": 2,
      "unit_price": 21.98,
      "line_total": 43.96
    },
    {
      "description": "1/2-IN PVC COUPLING 15-PA",
      "sku": "254896",
      "qty": 1,
      "unit_price": 3.49,
      "line_total": 3.49
    },
    {
      "description": "1/2-IN PVC TYPE C CONDUIT",
      "sku": "115839",
      "qty": 1,
      "unit_price": 4.39,
      "line_total": 4.39
    }
  ]
}
```

---

## Edge Cases

### 1. Duplicate Subtotal Lines
Lowe's receipts may contain multiple subtotal lines:
```
Invoice 89357 Subtotal
$ 51.84
Invoice 89357 Subtotal
$ 51.84
Subtotal
$ 51.84
```
Parser returns first valid match.

### 2. Forwarded Email Headers
When receipt is forwarded, email metadata appears in body:
```
Begin forwarded message:
From: Lowe's Home Improvement <do-not-reply@receipt.lowes.com>
Subject: Your Lowe's Purchase Receipt
Date: December 31, 2025 at 1:04:12 PM EST
To: user@email.com
```
These are parsed for vendor/date but excluded from line items.

### 3. Military Discount Message
```
Thank You For Your Military Service
```
Excluded by general text filtering (no product-like pattern).

### 4. Survey Block
Large text block with asterisks containing survey info is excluded by keyword filters (`survey`, `feedback`).

---

## Implementation Reference

Parser implementation: `supabase/functions/api/handlers/inbound_receipt_email.ts`

Key functions:
- `extractReceiptFields()` - Main parsing orchestrator
- `extractLabeledAmount()` - Multi-line totals extraction
- `extractVendorFromLabels()` - Vendor name with email cleanup
- `extractSkuFromLine()` - Item # pattern matching
- `isLineItemExcluded()` - Exclusion rule engine
- `decodeHtmlEntities()` - Entity decoding

---

## Testing

To test parser changes with Lowe's format:
```bash
# Simulated test
curl -X POST "https://<project>.supabase.co/functions/v1/api/inbound/receipt-email?token=<token>" \
  -F "to=receipts+<slug>@inbound.inventorymanager.modulus-software.com" \
  -F "from=test@example.com" \
  -F "subject=Test Lowes Receipt" \
  -F "text=<receipt_text>"
```

---

## Changelog

| Date | Change |
|------|--------|
| 2026-01-08 | Initial parser rules documented |
| 2026-01-08 | Added multi-line totals extraction |
| 2026-01-08 | Added SKU extraction from Item # lines |
| 2026-01-08 | Added HTML entity decoding |
| 2026-01-08 | Extended qty search range for Lowe's format |
