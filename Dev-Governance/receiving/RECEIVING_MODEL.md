# Receiving Model (Receipt-Based)

Defines the receipt-based receiving model for Inventory Receiving v2.

## Purchase Order vs Receipt

- Purchase Order (PO): intent to buy with expected quantities. A PO does not
  change inventory and may be fulfilled by one or more receipts.
- Receipt: record of actual received quantities. Inventory updates come only
  from completed receipts, not from POs.

## Receipt Lifecycle

Core lifecycle:
- draft -> completed -> voided

Notes:
- Optional approval steps (for example, pending) may exist but must resolve to
  completed or back to draft without changing inventory until completion.
- Completed receipts are append-only and immutable; voiding reverses impact.

## Receipt Lines

Each receipt line represents an item and quantities received for that item.

Required fields:
- qty_received (aka received_qty in existing schema): quantity accepted into
  inventory.

Optional fields:
- qty_rejected (aka rejected_qty): quantity rejected; does not affect inventory.
- qty_expected (aka expected_qty): expected quantity from the PO line, used for
  validation and variance reporting.
- po_line_id: reference to a purchase order line (optional but recommended).

## Partial Receiving Rules

- A receipt may include a subset of PO lines or a subset of quantities.
- Multiple receipts may reference the same PO.
- Totals across receipts for a PO line should not exceed expected quantity;
  over-receiving is allowed only with explicit warning/override.
- No automatic receiving. No implicit full-order receipt.

## Inventory Update Rules

- Inventory updates occur only when a receipt is completed.
- Inventory changes are based only on receipt lines:
  item.quantity += qty_received for each line.
- qty_rejected has no inventory effect.
- Completion applies all line updates atomically in a single transaction.
- Voiding a completed receipt reverses the exact inventory impact.
- Receipt completion and void operations must be idempotent and auditable.
