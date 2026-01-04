# AI Development Constitution

## Purpose
This document defines the non-negotiable rules governing all AI-assisted software development under this workspace.

Its purpose is to:
- Preserve product legitimacy
- Prevent pricing and entitlement drift
- Eliminate undocumented behavior
- Protect founder time and support capacity
- Ensure long-term maintainability across products

This Constitution applies to all products, features, documentation, and pricing decisions.

---

## Scope
These rules apply to:
- All repositories under /products/*
- All features (planned, in progress, or implemented)
- All documentation and specifications
- All pricing, tiering, and entitlement behavior
- All AI tools (ChatGPT, Claude, Codex, or successors)

No exceptions are implied by speed, convenience, or partial implementation.

---

## Authority Hierarchy

The following documents are authoritative, in descending order:

1. AI_CONSTITUTION.md
2. FEATURE_REGISTRY_SCHEMA.yaml
3. PRICING_RULES.md
4. PAYMENTS_AND_ENTITLEMENTS.md
5. DOCS_SCHEMA.md
6. Per-product Feature Registries
7. Per-product pricing.md
8. Specifications and implementation

Lower-level artifacts must conform to higher-level ones.
Conflicts are resolved by adjusting the lower-level artifact, never the higher.

---

## Non-Negotiable Rules

1. No feature exists without a Feature Registry entry.
2. No code is written for an unregistered feature.
3. No feature is complete without compliant documentation.
4. Pricing tiers are engineering constraints, not marketing labels.
5. Entitlements must be enforced in backend logic.
6. Support-heavy behavior must be gated by tier.
7. Ambiguity must be resolved before implementation, not after.

---

## Feature Governance Rules

Every feature MUST declare:
- A stable, namespaced feature_id
- Tier availability across all tiers
- Expected support impact
- Lifecycle status

Support impact definitions:
- none: no support expected
- low: rare clarification
- medium: onboarding or workflow questions likely
- high: frequent or ongoing human assistance expected

Rules:
- Medium or high support-impact features MUST NOT be Starter tier
- High support-impact features MUST be Business tier or above
- High support-impact features MUST trigger a pricing review

---

## Documentation Rules

Documentation is a release requirement.

Rules:
- User-facing features require user-facing documentation
- Internal-only features require internal documentation
- Documentation must reflect actual behavior, not intent
- Changelog entries are mandatory for every release
- Silent changes are prohibited

If documentation is missing or ambiguous, the feature is incomplete.

---

## Payments and Entitlements Rules

- Payment state determines entitlements
- Entitlements must be evaluated continuously
- UI visibility does not grant access
- Downgrades must not delete data
- Upgrades must take effect immediately
- Ambiguous payment state defaults to restrictive behavior

Manual entitlement overrides indicate system failure and must be avoided.

---

## AI Operating Rules

AI tools are execution engines, not decision-makers.

AI MUST:
- Follow the Feature Registry schema exactly
- Respect tier and entitlement constraints
- Update documentation as part of completion
- Explicitly surface pricing or support concerns
- Stop and request clarification when ambiguity exists

AI MUST NOT:
- Invent features, tiers, or schema fields
- Downgrade governance to “move faster”
- Modify authoritative documents without instruction

---

## Conformance and Review

Implementation may proceed ahead of specifications temporarily.
However, before merge or release:

- Code MUST be reviewed against all authoritative documents
- Deviations MUST be corrected in code, not by rewriting specs
- Final approval requires conformance confirmation

---

## Prime Directive

Speed is not the objective.

Clarity, correctness, and durability are the objective.

A feature that ships late but correctly
is superior to a feature that ships early and creates confusion.
