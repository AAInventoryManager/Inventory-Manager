# Entitlement Model

## Purpose
Defines how entitlement tiers are resolved and enforced across the platform.

## Core Rule
Effective tier is computed deterministically:

effective_tier = highest_of(subscription_tier, tier_override)

Where:
- subscription_tier derives from billing subscriptions
- tier_override is an explicit manual override set by a super user
- highest_of uses the tier order documented below

Billing state alone does not grant entitlement. It only supplies subscription_tier.

If no subscription exists, subscription_tier = starter.
If tier_override is NULL, it is ignored.

## Tier Order (Explicit)
1. starter
2. professional
3. business
4. enterprise

## Super User Bypass
Super users bypass tier checks entirely for gated operations. This bypass is enforced server-side.

## Tier Resolution Output
The authoritative tier resolver returns:
- effective_tier
- tier_source (billing, override, super_user)
- billing_state (active, trial, grace, none)

## Manual Override Fields
Tier overrides are stored on companies:
- tier_override (enum)
- tier_override_reason
- tier_override_set_by
- tier_override_set_at

Overrides must be explicit, auditable, and require a reason.

## Determinism
Tier resolution never relies on UI state or permissions. The backend is the source of truth.
Billing ambiguity must surface via billing_state = none instead of silent promotion.
