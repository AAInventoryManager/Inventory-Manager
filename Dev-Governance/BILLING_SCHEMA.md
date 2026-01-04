# Billing Schema

## Tables

### billing_price_map
Maps provider price IDs to tiers.

Fields:
- provider (default: stripe)
- price_id (unique per provider)
- tier (starter, professional, business, enterprise)
- is_active

### billing_subscriptions
Represents the billing state for a company.

Key fields:
- company_id
- provider
- price_id
- status (active, trial, grace, inactive)
- current_period_start
- current_period_end
- trial_start / trial_end
- grace_start / grace_end
- metadata

## Billing State Resolution
A subscription is valid when:
- status is active, trial, or grace
- trial/grace windows are not expired

If no valid subscription exists, billing_state = none and subscription_tier = starter.
If multiple valid subscriptions exist, billing_state = none and subscription_tier = starter (most restrictive).

## Entitlement Link
Billing determines subscription_tier only. Final entitlements are resolved via the entitlement model (see ENTITLEMENT_MODEL.md).
