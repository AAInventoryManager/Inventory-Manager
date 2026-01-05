# Onboarding Wizard v2 Specification

**Feature ID:** `ONBOARDING_WIZARD_V2`
**Version:** 2.0.0
**Status:** Implemented
**Date:** 2024-12-29

---

## Overview

Enhanced onboarding wizard with improved UX, Google Places integration, and modernized visual theme matching the modulus website aesthetic.

---

## Features

### 1. Google Places Autocomplete

**Purpose:** Streamline address entry for company locations with Google as the canonical source.

**Implementation:**
- Google Places API integration with API key
- Autocomplete on location address field (`companyLocationAddress1`)
- Store the selected formatted address as the canonical location address
- Persist optional Google metadata when available (place ID + components)

**Field Mapping:**
```javascript
{
  address1: 'companyLocationAddress1',
  formatted: 'companyLocationAddress1Value',
  placeId: 'companyLocationPlaceId',
  components: 'companyLocationAddressComponents'
}
```

**Functions:**
- `initGooglePlaces()` - API callback
- `initAddressAutocomplete(inputId, fieldMapping)` - Setup autocomplete
- `populateAddressFields(components, mapping)` - Parse response
- `destroyAddressAutocomplete(inputId)` - Cleanup

---

### 2. Invite Company Dropdown Fix

**Purpose:** Ensure onboarding company appears in invite dropdown for super users.

**Problem Solved:**
- During onboarding, the newly created company wasn't appearing in the company dropdown
- Super users couldn't select the onboarding company to send invites

**Implementation:**
- Added `_onboardingCompanyId` state variable
- Set during `handleOnboardingRoute()` after company ID is available
- Modified `renderInviteUi()` to:
  1. Check if onboarding company exists in `SB.companies`
  2. If missing, add from `SB.company` object
  3. During onboarding route, default selection to onboarding company
- Cleared on `redirectToAppHome()` when onboarding completes

---

### 3. Timezone Selector Improvement

**Purpose:** Better timezone selection UX with US-first ordering and system detection.

**Implementation:**
- Replaced `<input list="datalist">` with grouped `<select>`
- Optgroup structure:
  1. **United States** (7 zones with friendly labels)
  2. **Canada**
  3. **Mexico & Caribbean**
  4. **Central & South America**
  5. **Europe**
  6. **Africa**
  7. **Asia**
  8. **Australia & Pacific**
  9. **Other**
  10. **Universal** (UTC)

**US Timezones:**
| Value | Label |
|-------|-------|
| `America/New_York` | Eastern (New York) |
| `America/Chicago` | Central (Chicago) |
| `America/Denver` | Mountain (Denver) |
| `America/Phoenix` | Mountain - Arizona (Phoenix) |
| `America/Los_Angeles` | Pacific (Los Angeles) |
| `America/Anchorage` | Alaska (Anchorage) |
| `Pacific/Honolulu` | Hawaii (Honolulu) |

**Auto-detection:**
- `getSystemTimezone()` uses `Intl.DateTimeFormat().resolvedOptions().timeZone`
- Fallback to `America/Chicago` if detection fails
- Applied as default when no saved timezone exists

---

### 4. Modernized Visual Theme

**Purpose:** Match website aesthetic (modulus-software.com).

**CSS Variables:**
```css
--wiz-bg: #09090b;
--wiz-bg-elevated: #18181b;
--wiz-accent: #00e5ff;
--wiz-secondary: #a855f7;
--wiz-text: #fafafa;
--wiz-muted: #71717a;
--wiz-border: #27272a;
--wiz-gradient: linear-gradient(135deg, #00e5ff 0%, #a855f7 100%);
```

**Visual Elements:**
- Dark background with cyan/purple glow effect
- Gradient border on card (mask composite technique)
- Outfit font family
- Gradient-filled progress bar with glow
- Pill-shaped buttons with hover lift animation
- Fade-in animations on step transitions
- Brand logo with gradient text at top
- Input focus states with cyan glow

**Scoping:**
- All styles scoped to `#onboardingMain` and `body.onboarding-route`
- Does not affect main application styling

---

## Files Modified

- `/index.html`
  - Line 13: Added Outfit font import
  - Lines 20-21: Google Places API script
  - Lines 2658-2941: Modernized onboarding CSS
  - Lines 3095-3099: Brand logo HTML
  - Lines 4385-4519: Google Places functions + timezone detection
  - Lines 7806-7848: Modified `renderInviteUi()` for onboarding company
  - Lines 13306-13316: Autocomplete init in location editor
  - Line 17057: Clear onboarding company ID on exit
  - Lines 17183-17275: New timezone select population
  - Lines 17296-17309: Updated form application with system timezone

---

## Dependencies

- Google Places API (key required)
- Google Fonts: Outfit
- Intl API for timezone support

---

## Browser Support

- Chrome 80+
- Firefox 75+
- Safari 14+
- Edge 80+

Requires `Intl.supportedValuesOf('timeZone')` support (Chrome 93+, Firefox 93+, Safari 15.4+). Graceful degradation for older browsers.
