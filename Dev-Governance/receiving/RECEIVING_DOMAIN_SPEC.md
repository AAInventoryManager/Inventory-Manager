# Receiving Domain Specification

> Domain governance document for inventory receiving operations.

## Overview

The **Receiving** domain handles the intake of goods into the inventory system. It bridges purchase orders, supplier shipments, and inventory records—ensuring accurate quantity tracking, quality verification, and audit compliance.

## Domain Boundaries

### In Scope
- Receipt creation and lifecycle management
- Line-item receiving against purchase orders
- Partial and complete receipt handling
- Quantity discrepancy resolution
- Damage/defect documentation
- Inventory quantity adjustments on receipt completion
- Receiving audit trail

### Out of Scope
- Purchase order creation (Procurement domain)
- Supplier management (Vendor domain)
- Warehouse bin/location assignment (Warehouse domain)
- Accounts payable reconciliation (Finance domain)

## Core Entities

### Receipt
Primary aggregate root for a receiving event.

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Primary key |
| `receipt_number` | string | Human-readable identifier (auto-generated) |
| `purchase_order_id` | UUID | FK to originating PO (nullable for ad-hoc) |
| `supplier_id` | UUID | FK to supplier |
| `status` | enum | Current state (see state machine) |
| `received_by` | UUID | FK to user who performed receiving |
| `received_at` | timestamp | Completion timestamp |
| `notes` | text | Free-form notes |
| `company_id` | UUID | Tenant isolation |
| `created_at` | timestamp | Record creation |
| `updated_at` | timestamp | Last modification |

### ReceiptLine
Individual line item within a receipt.

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Primary key |
| `receipt_id` | UUID | FK to parent receipt |
| `item_id` | UUID | FK to inventory item |
| `po_line_id` | UUID | FK to PO line (nullable) |
| `expected_qty` | integer | Quantity expected per PO |
| `received_qty` | integer | Actual quantity received |
| `rejected_qty` | integer | Quantity rejected (damaged/defective) |
| `rejection_reason` | text | Reason for rejection |
| `unit_cost` | decimal | Cost per unit at receipt |
| `lot_number` | string | Lot/batch tracking (optional) |
| `expiration_date` | date | For perishable items (optional) |

## Operations

### Commands
| Command | Description | Permissions |
|---------|-------------|-------------|
| `CreateReceipt` | Initialize a new receipt | `receiving:create` |
| `AddReceiptLine` | Add item line to receipt | `receiving:edit` |
| `UpdateReceiptLine` | Modify quantities/details | `receiving:edit` |
| `RemoveReceiptLine` | Remove line from receipt | `receiving:edit` |
| `SubmitReceipt` | Transition to pending approval | `receiving:edit` |
| `ApproveReceipt` | Approve and apply to inventory | `receiving:approve` |
| `RejectReceipt` | Reject receipt (return to draft) | `receiving:approve` |
| `VoidReceipt` | Cancel a completed receipt | `receiving:void` |

### Queries
| Query | Description | Permissions |
|-------|-------------|-------------|
| `GetReceipt` | Fetch single receipt with lines | `receiving:view` |
| `ListReceipts` | Paginated receipt list | `receiving:view` |
| `GetReceiptsByPO` | All receipts for a PO | `receiving:view` |
| `GetPendingReceipts` | Receipts awaiting approval | `receiving:view` |

## Events Emitted

| Event | Trigger | Consumers |
|-------|---------|-----------|
| `ReceiptCreated` | New receipt initialized | Audit log |
| `ReceiptSubmitted` | Receipt submitted for approval | Notifications |
| `ReceiptApproved` | Receipt approved | Inventory, Metrics |
| `ReceiptRejected` | Receipt sent back to draft | Notifications |
| `ReceiptVoided` | Completed receipt voided | Inventory, Audit log |
| `InventoryAdjusted` | Quantities applied to items | Metrics, Low-stock alerts |

## Integration Points

### Inbound
- **Purchase Orders**: Receipts can reference a PO for expected quantities
- **Suppliers**: Supplier context for receipt metadata

### Outbound
- **Inventory Items**: Quantity adjustments on approval
- **Audit Log**: All state transitions logged
- **Metrics**: Action counts for dashboard
- **Notifications**: Alerts for pending approvals

## Tier Availability

| Tier | Access |
|------|--------|
| Starter | Not available |
| Professional | Basic receiving (no approval workflow) |
| Business | Full receiving with approval workflow |
| Enterprise | Full + voiding + advanced audit |

## Permission Matrix

| Permission | Starter | Professional | Business | Enterprise |
|------------|---------|--------------|----------|------------|
| `receiving:view` | - | Yes | Yes | Yes |
| `receiving:create` | - | Yes | Yes | Yes |
| `receiving:edit` | - | Yes | Yes | Yes |
| `receiving:approve` | - | - | Yes | Yes |
| `receiving:void` | - | - | - | Yes |

---

## Open Questions

- [ ] Support for blind receiving (no PO reference)?
- [ ] Multi-location receiving (assign to specific warehouse)?
- [ ] Barcode/QR scanning integration for mobile?
- [ ] Photo attachment for damage documentation?
