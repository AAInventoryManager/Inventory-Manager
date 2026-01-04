# Pricing Rules

## Purpose
This document defines the rules governing pricing tiers across all products.

Pricing is treated as an engineering constraint, not a marketing decision.
Feature placement within tiers must reflect support cost, complexity, and long-term maintainability.

These rules apply to all products under this workspace.

---

## Tier Definitions

### Starter
Intent:
- Self-serve users
- Minimal complexity
- No expectation of human assistance

Rules:
- Only low or zero support-impact features allowed
- No workflow-based features
- No supplier, email, automation, or role-based systems
- Documentation must be sufficient for full self-service

---

### Professional
Intent:
- Small teams
- Moderate operational complexity
- Occasional clarification support

Rules:
- Medium support-impact features allowed
- Limited workflows permitted
- Features must remain intuitive without onboarding
- No features requiring ongoing human assistance

---

### Business
Intent:
- Operationally dependent customers
- Team workflows
- Business-critical usage

Rules:
- High support-impact features permitted
- Role-based systems allowed
- Supplier, email, automation, and lifecycle workflows allowed
- Support expectations must be explicitly documented

---

### Enterprise
Intent:
- Customers purchasing reliability, control, and access
- Willing to pay for reduced risk and higher touch

Rules:
- Any feature permitted
- Internal-only or advanced control features allowed
- Features that require human setup or review belong here
- May include non-user-facing governance or security capabilities

---

## Support Impact Rules

Support impact classifications:
- none: no expected support
- low: rare clarification
- medium: onboarding or workflow questions likely
- high: frequent or ongoing support expected

Rules:
- medium or high support-impact features MUST NOT be Starter tier
- high support-impact features MUST be Business tier or above
- Any feature with high support impact triggers a pricing review

Founder support time is valued at $150/hour and must be protected.

---

## Pricing Change Triggers

Pricing MUST be reviewed when:
- A new high-support feature is introduced
- A feature is expanded to a lower tier
- Workflow complexity increases
- Support volume materially changes

Pricing reviews are preventative, not reactive.

---

## Final Rule

If a feature is valuable enough to cause support load,
it is valuable enough to be paid for.
