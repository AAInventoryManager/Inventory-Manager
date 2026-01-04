# Self-Service Signup Flow Test Plan

**Feature ID:** `SELF_SERVICE_SIGNUP_V1`
**Version:** 1.0.0
**Date:** 2024-12-29

---

## Test Environment

- **Marketing Site:** modulus-software.com (or localhost for dev)
- **Application:** inventory.modulus-software.com (or localhost:5173)
- **Database:** Supabase local or staging
- **Browser:** Chrome (primary), Firefox, Safari, Edge

---

## Pre-Test Setup

1. Clear browser localStorage/cookies
2. Ensure no active Supabase session
3. Reset test database or use fresh email addresses
4. Verify Supabase local is running (`supabase status`)

---

## 1. Marketing Site - Pricing CTAs

### 1.1 CTA Button Links
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 1.1.1 | Starter tier CTA | Click "Get Started" on Starter tier | Navigates to `inventory.../onboarding?plan=starter` |
| 1.1.2 | Professional tier CTA | Click "Get Started" on Professional tier | Navigates to `inventory.../onboarding?plan=professional` |
| 1.1.3 | Business tier CTA | Click "Get Started" on Business tier | Navigates to `inventory.../onboarding?plan=business` |
| 1.1.4 | Enterprise tier CTA | Click "Contact Sales" on Enterprise | Opens email to sales@modulus-software.com |

### 1.2 Plan Parameter Persistence
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 1.2.1 | Plan shown in wizard | Click Professional tier CTA | Wizard shows "Professional Plan" indicator |
| 1.2.2 | Plan stored for signup | Complete signup | Company created with professional tier |

---

## 2. Signup Flow - Step 0: Create Account

### 2.1 Form Validation
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.1.1 | Empty email | Leave email blank, click Create | Error: "Email required" |
| 2.1.2 | Invalid email | Enter "notanemail", click Create | Error: "Invalid email format" |
| 2.1.3 | Empty password | Leave password blank, click Create | Error: "Password required" |
| 2.1.4 | Short password | Enter 5-char password | Error: "Password must be at least 8 characters" |
| 2.1.5 | Password mismatch | Enter different passwords | Error: "Passwords do not match" |
| 2.1.6 | Terms unchecked | Fill form, leave terms unchecked | Error: "Please accept Terms of Service" |

### 2.2 Successful Signup
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.2.1 | Valid signup | Fill valid email, matching 8+ char passwords, check terms | Account created, advances to Step 1 |
| 2.2.2 | Email auto-confirm (local) | Complete signup in local dev | Session active, no email verification needed |
| 2.2.3 | Duplicate email | Signup with existing email | Error: "User already registered" |

### 2.3 Alternative Flows
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 2.3.1 | Already have account | Click "Already have an account?" | Shows sign-in form |
| 2.3.2 | Sign in then continue | Sign in with existing account | Continues to company or profile step |

---

## 3. Signup Flow - Step 1: Name Your Company

### 3.1 Form Validation
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.1.1 | Empty company name | Leave name blank, click Continue | Error: "Company name required" |
| 3.1.2 | Whitespace only | Enter "   ", click Continue | Error: "Company name required" |

### 3.2 Company Creation
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.2.1 | Valid company name | Enter "Test Onboard Co.", click Continue | Company created, advances to Step 2 |
| 3.2.2 | Slug generation | Enter "My Test Company!" | Slug generated as "my-test-company" |
| 3.2.3 | Special characters | Enter "Acme & Sons, Inc." | Slug: "acme-sons-inc" |
| 3.2.4 | Company in database | Complete step | Company exists in `companies` table with correct tier |
| 3.2.5 | User linked | Complete step | User in `company_members` with role=admin |

### 3.3 Edge Cases
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 3.3.1 | Duplicate slug | Create company with same name as existing | Handles gracefully (suffix or error) |
| 3.3.2 | Very long name | Enter 200+ character name | Truncated or validated |
| 3.3.3 | Unicode characters | Enter "日本語 Company" | Handled gracefully |

---

## 4. Existing Onboarding Steps

### 4.1 Step 2: Company Profile
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.1.1 | Timezone auto-detected | Load profile step | System timezone pre-selected |
| 4.1.2 | Email pre-filled | Load profile step | Contact email = signup email |
| 4.1.3 | Save profile | Fill fields, click Continue | Settings saved to company |

### 4.2 Step 3: Locations
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.2.1 | Add location | Click Add Location, fill form | Location modal opens |
| 4.2.2 | Google Places autocomplete | Type address in Address 1 | Suggestions appear |
| 4.2.3 | Location saved | Complete location form | Location appears in list |

### 4.3 Step 4: Invite Team
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.3.1 | Company in dropdown | View invite section | New company is in dropdown |
| 4.3.2 | Send invite | Enter email, select role, click Send | Invite created |
| 4.3.3 | Skip invites | Click "Skip for now" | Advances to finish step |

### 4.4 Step 5: Finish
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 4.4.1 | Summary shown | Reach finish step | Shows company name, plan, setup summary |
| 4.4.2 | Complete onboarding | Click "Start Using Inventory Manager" | Redirects to main app |
| 4.4.3 | Onboarding state | After completion | State = ONBOARDING_COMPLETE |

---

## 5. Progress Indicator

### 5.1 New User Flow (6 steps)
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 5.1.1 | Step 0 active | On account step | "Account" pill highlighted |
| 5.1.2 | Step 1 active | On company step | "Company" pill highlighted, Account complete |
| 5.1.3 | Progress bar | Move through steps | Bar fills proportionally (0%, 17%, 33%, 50%, 67%, 83%, 100%) |

### 5.2 Existing User Flow (4 steps)
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 5.2.1 | Skip account/company | Sign in with existing company, go to /onboarding | Shows 4-step progress |

---

## 6. Error Handling

### 6.1 Network Errors
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 6.1.1 | Signup network fail | Disconnect network during signup | Error message, retry option |
| 6.1.2 | Company creation fail | Disconnect during company step | Error message, form preserved |

### 6.2 Session Handling
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 6.2.1 | Session timeout | Wait for session to expire mid-flow | Graceful redirect to re-auth |
| 6.2.2 | Duplicate tab | Open onboarding in two tabs | Both work independently |

---

## 7. Security Tests

### 7.1 Input Sanitization
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 7.1.1 | XSS in company name | Enter `<script>alert('x')</script>` | Escaped, no script execution |
| 7.1.2 | SQL injection | Enter `'; DROP TABLE companies;--` | No SQL execution, treated as text |

### 7.2 Authorization
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 7.2.1 | Create company without auth | Call RPC without session | Error: "Authentication required" |
| 7.2.2 | Create second company | Try to create another company | Error: "User already belongs to a company" |

---

## 8. End-to-End Flow Tests

### 8.1 Complete Happy Path
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 8.1.1 | Full signup flow | 1. Click Professional on marketing site<br>2. Create account<br>3. Name company<br>4. Fill profile<br>5. Add location<br>6. Skip invites<br>7. Finish | User in app dashboard with working company |

### 8.2 Resume After Abandonment
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 8.2.1 | Close after account | Create account, close tab, return | Resumes at company step |
| 8.2.2 | Close after company | Create company, close tab, return | Resumes at profile step |

---

## 9. Visual/UI Tests

### 9.1 Theme Consistency
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 9.1.1 | New steps match theme | View account and company steps | Same gradient border, colors, fonts |
| 9.1.2 | Animations | Navigate between steps | Fade-in animations work |

### 9.2 Responsive Design
| # | Test Case | Steps | Expected Result |
|---|-----------|-------|-----------------|
| 9.2.1 | Mobile signup | 375px width | Form usable, no overflow |
| 9.2.2 | Tablet signup | 768px width | Proper layout |

---

## Sign-off

| Role | Name | Date | Status |
|------|------|------|--------|
| Developer | | | |
| QA | | | |
| Product | | | |
