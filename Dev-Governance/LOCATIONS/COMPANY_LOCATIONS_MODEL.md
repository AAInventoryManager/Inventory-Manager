# Company Locations Model

## Purpose
A Location is a company-owned operational address used for shipping, receiving,
warehousing, yards, offices, and future job sites. Locations allow purchasing
and receiving workflows to reference consistent ship-to/receive-at destinations
with auditability and defaults.

This phase does not introduce multi-location inventory quantities or valuation.

## Location Types
Locations carry a type for reporting and UI filtering.
Allowed values:
- warehouse
- yard
- office
- job_site
- other

## Address Field Allowlist
Only the following address fields are permitted in the canonical location
record. Required fields are listed in the Minimum Viable Location Record
section.

- name (display label)
- location_type
- address_line1
- address_line2 (optional)
- city
- state_region
- postal_code
- country_code (ISO-3166-1 alpha-2)
- contact_name (optional)
- contact_phone (optional)
- contact_email (optional)
- delivery_notes (optional)

## Defaults
Companies may define two independent defaults:
- default_ship_to_location_id
- default_receive_at_location_id

Defaults are used to prefill new purchasing/receiving flows. If a location is
archived, it cannot remain the default and must be reassigned or cleared.

## Minimum Viable Location Record
The following fields are required and must be non-empty:
- company_id
- name
- location_type
- address_line1
- city
- state_region
- postal_code
- country_code

## Relationships
- Purchase Orders reference ship_to_location_id.
  - v1 behavior: ship_to_location_id may be NULL; the system should fall back
    to default_ship_to_location_id when creating a new PO.
- Receipts reference receive_at_location_id.
  - v1 behavior: receive_at_location_id may be NULL; the system should fall back
    to default_receive_at_location_id when creating a receipt.
- Jobs may reference job_site_location_id (future).

## Lifecycle
Locations are active by default and may be archived (soft-deleted). Hard deletes
are restricted when references exist.

## Gating / Onboarding Notes (Document Only)
Purchasing and receiving should require at least one active location before the
features are enabled. Enforcement will be handled later by the onboarding state
machine and is not part of this phase.
