# Audit Events

Audit records are immutable and append-only. All entitlement changes must
emit an audit event with the required fields below.

## Event: entitlement.company_tier.base_changed
- Trigger condition:
  - Base subscription tier for a company changes via billing or manual
    super_user action that sets base tier.
- Required fields:
  - company_id
  - actor_user_id (super_user or system)
  - previous_effective_tier
  - new_effective_tier
  - override_duration_seconds (NULL)
  - timestamp

## Event: entitlement.company_tier.override_granted
- Trigger condition:
  - A super_user creates a new override record.
- Required fields:
  - company_id
  - actor_user_id (super_user)
  - previous_effective_tier
  - new_effective_tier
  - override_duration_seconds (NULL if no ends_at)
  - timestamp

## Event: entitlement.company_tier.override_revoked
- Trigger condition:
  - A super_user revokes an active override early.
- Required fields:
  - company_id
  - actor_user_id (super_user)
  - previous_effective_tier
  - new_effective_tier
  - override_duration_seconds (remaining duration at revocation)
  - timestamp

## Event: entitlement.company_tier.override_expired
- Trigger condition:
  - An active override passes its ends_at boundary and is no longer active.
- Required fields:
  - company_id
  - actor_user_id (system)
  - previous_effective_tier
  - new_effective_tier
  - override_duration_seconds (original duration)
  - timestamp

## Event: inventory_seeded
- Trigger condition:
  - A super_user performs an explicit inventory seeding operation from a source
    company or template catalog into a target company.
- Required fields:
  - actor_user_id
  - source_company_id
  - target_company_id
  - mode
  - items_copied_count
  - dedupe_key
  - timestamp

## Event: company_provisioned
- Trigger condition:
  - A super_user creates a company via provisioning (dev tooling / platform UI).
- Required fields:
  - company_id
  - actor_user_id
  - source_company_id (NULL if no inventory copy)
  - inventory_seeded (boolean)
  - users_added_count
  - timestamp

## Event: company_members_added
- Trigger condition:
  - Provisioning adds existing users to a company.
- Required fields:
  - company_id
  - actor_user_id
  - user_ids
  - roles
  - timestamp

## Event: company_environment_changed
- Trigger condition:
  - A super_user changes a company's environment classification.
- Required fields:
  - company_id
  - from_environment
  - to_environment
  - actor_user_id
  - timestamp

## Event: receipt_created
- Trigger condition:
  - A new receipt record is created (draft state).
- Required fields:
  - receipt_id
  - purchase_order_id
  - company_id
  - actor_user_id
  - timestamp

## Event: receipt_completed
- Trigger condition:
  - A receipt transitions to completed and posts inventory.
- Required fields:
  - receipt_id
  - purchase_order_id
  - company_id
  - actor_user_id
  - timestamp

## Event: receipt_voided
- Trigger condition:
  - A completed receipt is voided and inventory is reversed.
- Required fields:
  - receipt_id
  - purchase_order_id
  - company_id
  - actor_user_id
  - timestamp

## Event: receipt_line_received
- Trigger condition:
  - A receipt line posts its received quantity as part of receipt completion.
- Required fields:
  - receipt_id
  - purchase_order_id
  - company_id
  - actor_user_id
  - timestamp

## Event: location_created
- Trigger condition:
  - A new company location record is created.
- Required fields:
  - location_id
  - company_id
  - actor_user_id
  - timestamp
  - changed_fields (summary or full record snapshot)

## Event: location_updated
- Trigger condition:
  - An existing location record is updated.
- Required fields:
  - location_id
  - company_id
  - actor_user_id
  - timestamp
  - changed_fields (summary of modified fields)

## Event: location_archived
- Trigger condition:
  - A location is archived (soft-deleted).
- Required fields:
  - location_id
  - company_id
  - actor_user_id
  - timestamp
  - changed_fields (archive state and any dependent updates)

## Event: location_default_changed
- Trigger condition:
  - The default ship-to or receive-at location changes.
- Required fields:
  - location_id
  - company_id
  - actor_user_id
  - timestamp
  - default_kind (ship_to or receive_at)
  - previous_location_id
  - new_location_id
  - changed_fields (summary of default change)

## Event: onboarding_state_changed
- Trigger condition:
  - A company's onboarding state changes.
- Required fields:
  - company_id
  - from_state
  - to_state
  - actor_user_id
  - timestamp

## Field Notes
- `actor_user_id` is required; use a system sentinel when no human actor exists.
- `previous_effective_tier` and `new_effective_tier` must reflect the
  resolver output at the time of the event.
- `override_duration_seconds` is computed as:
  - NULL when no override duration applies.
  - ends_at - starts_at for granted/expired events with a time limit.
  - ends_at - now() for revocation events (remaining duration).
