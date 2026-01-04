# Inventory Manager Development Standards

**Version:** 1.0
**Last Updated:** January 2026
**Status:** Active

---

## Overview

This document establishes development standards for the Inventory Manager application. All new features and modifications must comply with these standards.

---

## 1. UI Component Standards

### 1.1 Universal Dynamic Width Engine (UDWE)

**Status:** REQUIRED for all modal tables

All tables rendered within modals MUST use the Universal Dynamic Width Engine (UDWE). This ensures:
- Consistent modal sizing across the application
- Content-driven widths (no arbitrary viewport stretching)
- Proper mobile responsiveness (stacked card layouts)
- No header truncation
- Smart body text truncation for long content

#### Compliance Requirements

| Requirement | Description |
|-------------|-------------|
| Config Registration | All tables must have a registered `UDWE_TABLE_CONFIG` |
| Column Definitions | All columns must define `minWidth`, `maxWidth`, and `truncatable` |
| Mobile Layout | Config must specify `mobileLayout`, `mobilePrimaryKey`, and `mobileSecondaryKeys` |
| No Raw Tables | Do not use raw `<table>` HTML in modals; use `UDWE.renderTable()` |

#### Example Usage

```javascript
// 1. Define table config
const MY_TABLE_CONFIG = {
  id: 'my_feature_table',
  columns: [
    { key: 'name', label: 'Name', type: 'text', minWidth: 140, maxWidth: 240,
      truncatable: false, align: 'left', priority: 1, locked: true },
    { key: 'value', label: 'Value', type: 'number', minWidth: 80, maxWidth: 100,
      truncatable: false, align: 'center', priority: 2, locked: true },
  ],
  baselineWidth: 480,
  minWidth: 320,
  maxWidth: 600,
  mobileBreakpoint: 600,
  mobileLayout: 'stacked',
  mobilePrimaryKey: 'name',
  mobileSecondaryKeys: ['value'],
};

// 2. Render using UDWE
const tableHtml = UDWE.renderTable(MY_TABLE_CONFIG, data);
```

#### Exceptions

UDWE is NOT required for:
- Main inventory list table (has its own specialized engine)
- Non-modal tables (e.g., inline report tables)
- Static content tables in documentation/help

To request an exception, document the rationale in the feature spec.

---

### 1.2 Modal Sizing

| Property | Standard Value |
|----------|----------------|
| Baseline Width | 480px |
| Minimum Width | 320px |
| Maximum Width | 800px (unless data-dense, then 1000px max) |
| Mobile Breakpoint | 600px |

Modals should grow/shrink based on content, not stretch to fill viewport.

---

### 1.3 Glassmorphism Design System

All UI components must follow the established glassmorphism design system:
- Frosted glass backgrounds: `rgba(13, 18, 24, 0.65)` with `backdrop-filter: blur()`
- Subtle borders: `1px solid var(--border)`
- Rounded corners: `12px` for cards/modals, `10px` for inputs, `8px` for buttons
- Consistent spacing: 8px base unit

---

## 2. Mobile-First Requirements

### 2.1 No Horizontal Scrolling

Horizontal scrolling is prohibited except as an absolute last resort. Solutions in order of preference:
1. Transform table to stacked card layout (UDWE handles this)
2. Prioritize columns (hide lower-priority columns on mobile)
3. Use collapsible/expandable sections
4. Only if none of the above work: horizontal scroll with clear affordance

### 2.2 Touch Targets

All interactive elements must have minimum touch target of 44x44px on mobile.

---

## 3. Accessibility Standards

### 3.1 ARIA Labels

All interactive elements must have appropriate ARIA labels:
- Buttons: `aria-label` describing the action
- Modals: `aria-modal="true"`, `aria-labelledby` pointing to title
- Tables: `role="table"` (implicit), proper `<th>` scope attributes

### 3.2 Keyboard Navigation

All features must be fully operable via keyboard:
- Tab order must be logical
- Focus must be visible
- Escape closes modals
- Enter/Space activates buttons

---

## 4. Feature Development Checklist

Before submitting any new feature for review, verify:

### Planning
- [ ] Feature registered in `feature_registry.yaml`
- [ ] Tier availability defined
- [ ] Support impact assessed

### UI Compliance
- [ ] UDWE used for all modal tables
- [ ] Mobile layout tested and functional
- [ ] No horizontal scrolling on mobile
- [ ] Glassmorphism styling applied
- [ ] Touch targets >= 44px on mobile

### Accessibility
- [ ] ARIA labels present
- [ ] Keyboard navigation works
- [ ] Focus management correct for modals

### Code Quality
- [ ] Functions documented with JSDoc comments
- [ ] Error handling for edge cases
- [ ] Console errors/warnings resolved

---

## 5. Deprecated Patterns

Do NOT use these patterns in new code:

| Deprecated | Use Instead |
|------------|-------------|
| Raw `<table>` in modals | `UDWE.renderTable()` |
| Fixed pixel widths for modals | UDWE baseline/min/max system |
| `overflow-x: scroll` on mobile | Stacked card layout |
| Hard-coded breakpoints | Use `UDWE.getLayoutMode()` or CSS variables |

---

## Appendix: UDWE Column Type Reference

| Type | Description | Typical minWidth |
|------|-------------|------------------|
| `text` | General text content | 120-180px |
| `number` | Numeric values (uses tabular-nums) | 70-100px |
| `date` | Date/datetime display | 100-140px |
| `status` | Status badge/pill | 90-130px |
| `actions` | Action buttons | 80-160px |
| `icon` | Icon-only column | 40-50px |

---

## 6. Related Documentation

| Document | Description |
|----------|-------------|
| [Job Approval Inventory Guardrail](./JOB_APPROVAL_INVENTORY_GUARDRAIL.md) | Defines when job approval should be blocked due to inventory changes |

---

**Document History**
- v1.0 (Jan 2026): Initial standards established with UDWE requirement
- v1.1 (Jan 2026): Added reference to Job Approval Inventory Guardrail
