# Admin Operations

## Manual Tier Overrides
Manual tier overrides are allowed for:
- Gifting tiers
- Internal testing
- Partnerships
- Demos

Overrides are not automatic and must be explicitly set by a super user.

## How to Set an Override
Use the governed RPC:

set_company_tier_override(company_id, tier, reason)

Requirements:
- Caller must be super_user
- tier must be one of: starter, professional, business, enterprise
- reason is required

## How to Clear an Override
Call the same RPC with tier = NULL and a reason.

## Audit Expectations
Every override change must:
- Update tier_override fields on companies
- Emit an audit_log entry with old/new values
- Include the reason and actor
