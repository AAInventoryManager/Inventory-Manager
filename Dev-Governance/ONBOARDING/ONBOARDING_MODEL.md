# Company Onboarding State Machine

## Purpose
Track onboarding progress for each company, gate features until prerequisites
are met, and support both self-serve and super-user provisioning flows.

## States
- UNINITIALIZED
  - Company record exists but onboarding has not started.
  - Subscription is not active; onboarding features remain gated.
- SUBSCRIPTION_ACTIVE
  - Company has an active subscription or an admin-enabled billing status.
  - Company profile can be completed.
- COMPANY_PROFILE_COMPLETE
  - Required company profile details are complete (name, address, timezone,
    primary contact, and any required compliance fields).
  - Location setup is now unblocked.
- LOCATIONS_CONFIGURED
  - At least one active location exists and is usable for operations.
  - Inventory receive flows are now unblocked.
- USERS_INVITED
  - Required user invitations are sent (at least one non-owner user when
    applicable to the plan).
  - Final onboarding checks can complete.
- ONBOARDING_COMPLETE
  - All prerequisites across profile, locations, and users are satisfied.
  - Full feature access is enabled.

## Allowed Transitions
### Standard progression
- UNINITIALIZED -> SUBSCRIPTION_ACTIVE
- SUBSCRIPTION_ACTIVE -> COMPANY_PROFILE_COMPLETE
- COMPANY_PROFILE_COMPLETE -> LOCATIONS_CONFIGURED
- LOCATIONS_CONFIGURED -> USERS_INVITED
- USERS_INVITED -> ONBOARDING_COMPLETE

### Administrative fast-forward
Fast-forward transitions require all prerequisite conditions for the target
state, including an active subscription.
- UNINITIALIZED -> COMPANY_PROFILE_COMPLETE (when profile prerequisites are met)
- UNINITIALIZED -> LOCATIONS_CONFIGURED (when profile and location prerequisites are met)
- UNINITIALIZED -> USERS_INVITED (when profile, location, and invite prerequisites are met)
- UNINITIALIZED -> ONBOARDING_COMPLETE (when all prerequisites are met)
- SUBSCRIPTION_ACTIVE -> LOCATIONS_CONFIGURED (when profile and location prerequisites are met)
- SUBSCRIPTION_ACTIVE -> USERS_INVITED (when profile, location, and invite prerequisites are met)
- SUBSCRIPTION_ACTIVE -> ONBOARDING_COMPLETE (when all prerequisites are met)
- COMPANY_PROFILE_COMPLETE -> USERS_INVITED (when location and invite prerequisites are met)
- COMPANY_PROFILE_COMPLETE -> ONBOARDING_COMPLETE (when all prerequisites are met)
- LOCATIONS_CONFIGURED -> ONBOARDING_COMPLETE (when invite prerequisites are met)
