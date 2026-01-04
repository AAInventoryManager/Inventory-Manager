# Company Provisioning Model

## Definition
Company provisioning is a super_user-only, platform-scoped workflow that
creates a new company and optionally seeds inventory and assigns existing
users with roles. It is an explicit, admin-driven action used for recovery,
demos, and controlled onboarding.

## Scope
- Platform-scoped UI (Dev tab in Company Switcher).
- super_user only.
- Uses governed inventory seeding when copy is requested.

## Inputs
- company_name (required)
- company_slug (optional; derived if omitted)
- subscription_tier (optional; when set, apply entitlement override)
- subscription_tier_reason (optional; default "Provisioning")
- seed_inventory (optional boolean)
- source_company_id (required when seed_inventory = true)
- user_assignments (optional list of { user_id, role })
- include_actor_as_admin (default true)

## Workflow
1. Validate inputs and authorization.
2. Create company record with default tier = starter and onboarding_state = UNINITIALIZED.
3. Create membership for actor if include_actor_as_admin = true.
4. Add optional user assignments (existing users only).
5. If subscription_tier is provided, apply entitlement override using the governed
   tier override workflow and emit entitlement audit events.
6. If requested, seed inventory using MODE_A from INVENTORY_SEEDING_MODEL.
7. Return company_id and summary.

## User Assignment Rules
- Roles limited to: viewer, member, admin.
- super_user role is never assignable via UI.
- Users must already exist in auth.
- Duplicate user_ids are rejected.
- Cross-company memberships are allowed for provisioning; UI must warn that
  these memberships are intended for test/super_user accounts.

## Inventory Copy
- Uses INVENTORY_SEEDING_MODEL (MODE_A items_only).
- Must emit inventory_seeded audit event when run.
- No quantities, transactions, suppliers, or history are copied.

## Auditing
- company_provisioned
- company_members_added (when assignments occur)
- inventory_seeded (when inventory copy occurs)

## Explicit Non-Goals (v1)
- Copying locations, receipts, orders, jobs, or audit history.
- Creating new auth users or sending invites.
- Billing activation or subscription checkout.
