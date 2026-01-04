# Documentation Schema

## Purpose
This document defines the required documentation structure for all products and features.

Documentation is treated as a first-class artifact.
No feature is considered complete unless its required documentation exists and is accurate.

These rules apply to all products under this workspace.

---

## Documentation Categories

Documentation is divided into two categories:

1. User-Facing Documentation
2. Internal Documentation

AI tools must respect this distinction.

---

## User-Facing Documentation

User-facing documentation exists to help customers understand:
- What a feature does
- Who it is for
- How to use it safely
- What its limitations are

### Required Sections (per feature)

Each user-facing feature document MUST include:

- **Overview**
  - Plain-English description of the feature
  - What problem it solves

- **Tier Availability**
  - Explicit list of tiers where the feature is available

- **How It Works**
  - High-level explanation of behavior
  - No implementation details

- **Limitations**
  - What the feature does NOT do
  - Known constraints or edge cases

- **Support Expectations**
  - What users can reasonably expect
  - When to contact support vs self-serve

---

## Internal Documentation

Internal documentation exists to protect maintainability and governance.

Examples:
- Security checklists
- Architectural decisions
- Feature lifecycle notes
- Pricing or support rationale

Internal documentation:
- Is not user-facing
- May exist only in Enterprise tier
- Must still be tracked and versioned

---

## Changelog Requirements

Every release MUST include a changelog entry.

Each changelog entry must:
- Reference feature_id values
- Clearly state what changed
- Avoid marketing language
- Be understandable to an existing user

No silent changes.

---

## Documentation Triggers

Documentation MUST be created or updated when:
- A new feature is introduced
- A feature changes behavior
- Tier availability changes
- Support expectations change
- A feature is deprecated

---

## Documentation Enforcement Rule

If documentation is missing, outdated, or ambiguous:
- The feature is considered incomplete
- Release must be delayed until corrected

Documentation accuracy is a release requirement, not an afterthought.
