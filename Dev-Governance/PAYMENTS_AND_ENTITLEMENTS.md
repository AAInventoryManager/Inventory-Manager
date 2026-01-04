# Payments and Entitlements

## Purpose
This document defines how paid plans, tiers, and entitlements behave across all products.

Payments are treated as a first-class engineering concern.
Entitlement behavior must be deterministic, predictable, and enforceable by code.

These rules apply to all products under this workspace.

---

## Core Concepts

### Tier
A tier represents a bundle of features, support expectations, and operational behavior.

Tiers are:
- Starter
- Professional
- Business
- Enterprise

Tiers are defined by engineering constraints, not marketing promises.

---

### Plan
A plan is a billable offering that maps directly to a tier.

Each plan:
- Corresponds to exactly one tier
- Has a fixed billing interval (monthly or annual)
- Grants entitlements based on tier

Plans do not overlap tiers.

---

### Subscription
A subscription represents an active or inactive payment state for a plan.

A subscription:
- Belongs to one customer or organization
- Grants entitlements while active
- Is evaluated continuously for entitlement enforcement

---

### Entitlement
An entitlement is the runtime permission to access a feature or behavior.

Entitlements are derived from:
- Active subscription status
- Tier mapping
- Role permissions (if applicable)

Entitlements are enforced at runtime, not inferred.

---

### Seat
A seat represents one user’s access to a product.

Initial assumption:
- All plans include a single seat by default
- Multi-seat behavior is out of scope unless explicitly added

---

## Tier to Entitlement Mapping

### General Rules
- Feature access is determined by tier entitlements
- Entitlements are evaluated on every request
- UI visibility does not imply entitlement

A feature may be:
- Fully enabled
- Read-only
- Hidden
- Blocked with upgrade messaging

Behavior must be explicit and consistent.

---

### Upgrade Behavior
When a customer upgrades:
- New entitlements take effect immediately
- No restart or manual intervention required
- Previously blocked features become accessible instantly

---

### Downgrade Behavior
When a customer downgrades:
- Entitlements are reduced immediately
- No data is deleted
- Features become read-only or inaccessible as defined per feature

Downgrades must never cause data loss.

---

## Trial Behavior

### Trial Definition
A trial is a temporary subscription granting limited entitlements.

Trial rules:
- Trials are time-bound
- Trial entitlements are explicitly defined
- Trials may mirror a paid tier or be more restrictive

---

### Trial Expiration
When a trial expires:
- Entitlements are downgraded to Starter
- No data is deleted
- Read-only access may be granted where appropriate

No silent behavior changes.

---

## Payment Failure Handling

### Grace Period
After a payment failure:
- A grace period may be applied
- Full entitlements remain active during grace

Grace duration is product-defined.

---

### Hard Stop
After grace period expiration:
- Subscription is marked inactive
- Paid-tier entitlements are revoked
- Product enters restricted mode

Restricted mode behavior must be explicit and documented.

---

### Reactivation
When payment is restored:
- Entitlements are restored immediately
- No manual support intervention required

---

## Support Entitlement Coupling

Support access is tied directly to tier.

### Starter
- No human support guaranteed
- Self-serve documentation only

---

### Professional
- Email support
- Best-effort response
- No SLA

---

### Business
- Priority support
- Faster response expectations
- Workflow-related assistance allowed

---

### Enterprise
- Rapid response expectations
- Direct communication channels permitted
- Support scope may include configuration guidance

Support entitlements are not retroactive.

---

## Enforcement Rules

- Entitlements must be enforced in backend logic
- UI alone must not gate access
- Entitlement checks must be explicit and testable
- Manual overrides should be avoided

If manual intervention is required, it indicates a system failure.

---

## Non-Goals

The following are explicitly out of scope unless added later:

- Usage-based billing
- Per-action pricing
- Proration logic
- Custom contracts
- Complex invoicing workflows

These exclusions are intentional.

---

## Final Rule

If payment state is ambiguous,
the system must default to the most restrictive entitlement behavior.
