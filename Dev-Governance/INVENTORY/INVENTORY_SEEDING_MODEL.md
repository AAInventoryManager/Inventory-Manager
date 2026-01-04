# Inventory Seeding Model

## Definition
Inventory seeding is a one-time, explicit copy of inventory item definitions from a source
company or template catalog into a target company. It creates new items owned by the target
company and does not copy transaction history or operational data.

## Authorization
- super_user only.

## Allowed Source -> Target Relationships
- Source: an existing company_id or a designated template catalog (system-owned).
- Target: any company_id selected for provisioning or admin-driven setup.
- Source and target must be different company_ids.
- Cross-company seeding is only allowed for super_user.

## Supported Modes
- MODE_A: items_only (default) - copy item definitions only.

## Allowed Fields (Allowlist)
For MODE_A, copy only the following item definition fields:
- name
- description
- sku
- barcode
- unit_of_measure
- reorder_point
- reorder_quantity
- low_stock_qty
- reorder_enabled
- is_active
- image_url

## Disallowed Fields (Denylist)
- quantity
- unit_cost
- sale_price
- metadata (may contain PII or supplier data)
- category_id, location_id (company-specific references)
- created_at, updated_at, created_by
- deleted_at, deleted_by
- id, company_id
- any supplier, receipt, or audit data
- any transaction history

## Dedupe Strategy
- Default dedupe key: sku (case-insensitive, trimmed).
- Fallback dedupe key: item name (case-insensitive, trimmed) when sku is null or blank.
- Dedupe occurs within the target company only.
- Existing target items that match the dedupe key are not modified.

## Idempotency Rules
- Seeding is allowed only once per target company by default.
- A repeated seed requires explicit force approval and must be audited as a separate run.
- Dedupe is always applied even when forced.
