# Company Locations Invariants

These are hard constraints, not guidelines.

## Company Scope
- Every location is owned by exactly one company.
- Cross-company references are forbidden: any reference to a location must have
  the same company_id as the referencing record.

## Required Address Fields
- Required fields for a location are defined in COMPANY_LOCATIONS_MODEL.md.
- Required fields must be present and non-empty.
- google_formatted_address is the canonical address; if google_place_id is
  provided it must be a valid Google Places identifier.

## Defaults
- Exactly one default_ship_to_location_id per company when at least one active
  location exists; otherwise none.
- Exactly one default_receive_at_location_id per company when at least one
  active location exists; otherwise none.
- Defaults must reference active (non-archived) locations.

## Deletion / Archival
- A location with active references (purchase_orders, receipts, or future jobs)
  cannot be hard-deleted.
- If a location must be removed, it must be archived or references must be
  reassigned first.
- Archiving a default location requires selecting a new default (or clearing the
  default if no active locations remain).

## Auditing
- The following actions must emit audit events:
  - create location
  - update location
  - archive (or delete) location
  - change default ship-to or receive-at location
- Audit records must include actor_user_id and a summary of changed fields.
