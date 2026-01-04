# Onboarding Wizard v2 Test Plan

**Feature ID:** `ONBOARDING_WIZARD_V2`
**Version:** 2.0.0
**Date:** 2024-12-29

---

## Test Environment

- Browser: Chrome (primary), Firefox, Safari
- Network: Connected (Google Places API required)
- User: Super user with onboarding company access

---

## 1. Google Places Autocomplete Tests

### 1.1 Autocomplete Initialization
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 1.1.1 | API loads successfully | Navigate to onboarding, open location editor | No console errors, `_googlePlacesReady = true` |
| 1.1.2 | Autocomplete appears on address field | Click in Address 1 field, type "123 Main" | Dropdown with Google Places suggestions appears |
| 1.1.3 | Styling matches theme | View autocomplete dropdown | Dark theme, white text, proper z-index |

### 1.2 Address Auto-population
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 1.2.1 | US address | Select "123 Main St, Austin, TX 78701" | All fields populate correctly |
| 1.2.2 | Canadian address | Select "123 King St W, Toronto, ON" | Country = Canada, Province populated |
| 1.2.3 | International address | Select address in UK or Germany | Correct country code, city, postal |
| 1.2.4 | Address with unit | Select "123 Main St #400" | Unit in Address 2 field |

### 1.3 Edge Cases
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 1.3.1 | API unavailable | Block googleapis.com, reload | Graceful degradation, manual entry works |
| 1.3.2 | Clear and re-type | Select address, clear field, type new | New suggestions appear |
| 1.3.3 | Modal close | Open modal, start typing, close modal | No orphaned dropdowns |

---

## 2. Invite Company Dropdown Tests

### 2.1 Onboarding Company Presence
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.1.1 | Company in dropdown | Navigate to Invite Users step | Onboarding company appears in dropdown |
| 2.1.2 | Default selection | Navigate to Invite Users step | Onboarding company is pre-selected |
| 2.1.3 | Company visible when missing from list | Onboarding company not in SB.companies | Company added from SB.company object |

### 2.2 Super User Behavior
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.2.1 | Super user can change company | Open dropdown, select different company | Selection updates, invite goes to new company |
| 2.2.2 | Non-super user | Log in as non-super user | Company dropdown hidden |

### 2.3 State Cleanup
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.3.1 | Exit onboarding | Complete onboarding, reach home | `_onboardingCompanyId` is empty string |
| 2.3.2 | Re-enter onboarding | Complete, then navigate to /onboarding | New company ID captured correctly |

---

## 3. Timezone Selector Tests

### 3.1 System Detection
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.1.1 | Auto-detect timezone | Fresh onboarding, no saved timezone | System timezone pre-selected |
| 3.1.2 | Saved timezone persists | Save timezone, reload profile step | Saved value displayed, not system value |
| 3.1.3 | Fallback timezone | Mock Intl failure | Falls back to America/Chicago |

### 3.2 Grouped Options
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.2.1 | US timezones first | Open timezone dropdown | "United States" group at top |
| 3.2.2 | All US zones present | Check US group | 7 zones with friendly labels |
| 3.2.3 | Regional groups | Scroll through dropdown | All optgroups present and populated |
| 3.2.4 | UTC available | Scroll to bottom | "Universal" group with UTC option |

### 3.3 Selection & Save
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.3.1 | Select and save | Choose "Pacific (Los Angeles)", save | Value saved to company settings |
| 3.3.2 | Reload persistence | Save timezone, refresh page | Same timezone displayed |
| 3.3.3 | Change timezone | Select different zone, save | New value saved |

---

## 4. Visual Theme Tests

### 4.1 Layout & Styling
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.1.1 | Dark background | Load onboarding | Background is #09090b |
| 4.1.2 | Cyan glow visible | View top of page | Radial gradient glow visible |
| 4.1.3 | Gradient border | View main card | Cyan-to-purple border visible |
| 4.1.4 | Brand logo | Check top of wizard | "modulus" in gradient text |

### 4.2 Typography
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.2.1 | Outfit font loads | Inspect text | Font-family includes 'Outfit' |
| 4.2.2 | Title styling | Check title | 28px, bold, proper color |
| 4.2.3 | Label styling | Check form labels | Uppercase, 12px, muted color |

### 4.3 Interactive Elements
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.3.1 | Button hover | Hover over primary button | Lifts 2px with enhanced shadow |
| 4.3.2 | Input focus | Click into input field | Cyan border with glow |
| 4.3.3 | Progress bar | Move through steps | Gradient fill with glow effect |
| 4.3.4 | Step pill active | View current step | Cyan color with glow |
| 4.3.5 | Step pill complete | Complete a step | Green color with bg |

### 4.4 Animations
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.4.1 | Initial fade-in | Load onboarding | 0.4s fade-in with slide |
| 4.4.2 | Step transition | Navigate between steps | 0.3s fade-in animation |

### 4.5 Responsive Design
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.5.1 | Mobile width | Resize to 375px | Card fits, text readable |
| 4.5.2 | Tablet width | Resize to 768px | Proper layout, no overflow |
| 4.5.3 | Wide screen | 1920px width | Centered, max-width 720px |

---

## 5. Integration Tests

### 5.1 Full Flow
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 5.1.1 | Complete onboarding | Step through all 4 steps | Redirects to app home |
| 5.1.2 | All features work together | Use autocomplete, set timezone, invite | All data saved correctly |
| 5.1.3 | Exit and resume | Complete step 2, close tab, return | Resumes at correct step |

### 5.2 Error Handling
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 5.2.1 | Network error | Disconnect during save | Error message displayed |
| 5.2.2 | Session timeout | Wait for session to expire | Redirect to login |

---

## Sign-off

| Role | Name | Date | Status |
|------|------|------|--------|
| Developer | | | |
| QA | | | |
| Product | | | |
