# Self-Service Signup Flow Specification

**Feature ID:** `SELF_SERVICE_SIGNUP_V1`
**Version:** 1.0.0
**Status:** Draft
**Date:** 2024-12-29
**Author:** Claude Code

---

## Overview

Enable self-service customer acquisition from the modulus-software.com marketing site through a complete signup and onboarding flow. Users can select a pricing tier, create an account, set up their company, and begin using the Inventory Manager application.

---

## User Journey

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MARKETING SITE                                       │
│                      modulus-software.com                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Landing Page  ──►  Pricing Section  ──►  Click "Get Started"              │
│                                              (with plan parameter)           │
│                                                                              │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         APPLICATION                                          │
│                   inventory.modulus-software.com                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   /onboarding?plan=professional                                              │
│                                                                              │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 0: CREATE ACCOUNT                                               │  │
│   │  - Email address                                                      │  │
│   │  - Password (with confirmation)                                       │  │
│   │  - Terms of Service checkbox                                          │  │
│   │  [Create Account]                                                     │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 1: NAME YOUR COMPANY                                            │  │
│   │  - Company name                                                       │  │
│   │  - (Auto-generates slug)                                              │  │
│   │  [Continue]                                                           │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 2: COMPANY PROFILE                                              │  │
│   │  - Primary contact email                                              │  │
│   │  - Timezone (auto-detected)                                           │  │
│   │  [Continue]                                                           │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 3: LOCATIONS                                                    │  │
│   │  - Add company locations (Google Places autocomplete)                 │  │
│   │  - At least one location required                                     │  │
│   │  [Continue]                                                           │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 4: INVITE TEAM                                                  │  │
│   │  - Invite users by email                                              │  │
│   │  - Assign roles                                                       │  │
│   │  - Skip option available                                              │  │
│   │  [Continue] [Skip for now]                                            │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  Step 5: FINISH                                                       │  │
│   │  - Summary of setup                                                   │  │
│   │  - Selected plan reminder                                             │  │
│   │  - Stripe payment (FUTURE - placeholder)                              │  │
│   │  [Start Using Inventory Manager]                                      │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                  │                                           │
│                                  ▼                                           │
│   Redirect to: /dashboard (main app)                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Technical Requirements

### 1. Marketing Site Changes (modulus-software.com)

**File:** `/Users/brandon/coding/modulus/index.html`

**Changes:**
- Update pricing tier CTA buttons to link to app signup
- Include plan parameter in URL

**Button URLs:**
| Tier | Current | New URL |
|------|---------|---------|
| Starter | `#` or none | `https://inventory.modulus-software.com/onboarding?plan=starter` |
| Professional | `#` or none | `https://inventory.modulus-software.com/onboarding?plan=professional` |
| Business | `#` or none | `https://inventory.modulus-software.com/onboarding?plan=business` |
| Enterprise | Contact form | `mailto:sales@modulus-software.com` (unchanged) |

---

### 2. Application Changes (Inventory Manager)

**File:** `/Users/brandon/coding/Inventory-Manager/index.html`

#### 2.1 New Onboarding Steps

Current steps: Profile → Locations → Invites → Finish
New steps: **Account → Company → Profile → Locations → Invites → Finish**

**Progress indicator update:**
- 6 steps instead of 4
- New step names in UI

#### 2.2 Step 0: Create Account

**HTML Elements:**
```html
<div class="onboarding-step" data-step="account">
  <h3>Create Your Account</h3>
  <div class="onboarding-grid">
    <div>
      <label>Email</label>
      <input id="signupEmail" type="email" required />
    </div>
    <div>
      <label>Password</label>
      <input id="signupPassword" type="password" required />
    </div>
    <div>
      <label>Confirm Password</label>
      <input id="signupPasswordConfirm" type="password" required />
    </div>
  </div>
  <div class="onboarding-terms">
    <label>
      <input type="checkbox" id="signupTerms" required />
      I agree to the <a href="/terms" target="_blank">Terms of Service</a>
    </label>
  </div>
  <div class="onboarding-actions">
    <button class="btn" id="btnSignupSignIn">Already have an account?</button>
    <button class="btn primary" id="btnSignupSubmit">Create Account</button>
  </div>
</div>
```

**JavaScript Logic:**
```javascript
async function handleSignupSubmit() {
  const email = $('signupEmail').value.trim();
  const password = $('signupPassword').value;
  const confirm = $('signupPasswordConfirm').value;
  const terms = $('signupTerms').checked;

  // Validation
  if (!email || !password) throw new Error('Email and password required');
  if (password !== confirm) throw new Error('Passwords do not match');
  if (password.length < 8) throw new Error('Password must be at least 8 characters');
  if (!terms) throw new Error('Please accept the Terms of Service');

  // Supabase signup
  const { data, error } = await SB.client.auth.signUp({
    email,
    password,
    options: {
      data: { signup_plan: state._signupPlan }
    }
  });

  if (error) throw error;

  // Proceed to company creation step
  advanceToStep('company');
}
```

#### 2.3 Step 1: Name Your Company

**HTML Elements:**
```html
<div class="onboarding-step" data-step="company">
  <h3>Name Your Company</h3>
  <div class="onboarding-grid">
    <div>
      <label>Company Name</label>
      <input id="signupCompanyName" type="text" placeholder="Acme Corporation" required />
    </div>
  </div>
  <div class="onboarding-actions">
    <button class="btn primary" id="btnCompanySubmit">Continue</button>
  </div>
</div>
```

**JavaScript Logic:**
```javascript
async function handleCompanyCreate() {
  const name = $('signupCompanyName').value.trim();
  if (!name) throw new Error('Company name required');

  // Generate slug
  const slug = name.toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

  // Create company via RPC
  const { data, error } = await SB.client.rpc('create_company_for_signup', {
    p_name: name,
    p_slug: slug,
    p_plan: state._signupPlan || 'starter'
  });

  if (error) throw error;

  // Store company ID and proceed
  SB.companyId = data.company_id;
  SB.company = { id: data.company_id, name, slug };

  advanceToStep('profile');
}
```

---

### 3. Database Changes

#### 3.1 New RPC: create_company_for_signup

**File:** `/supabase/migrations/032_signup_rpc.sql`

```sql
CREATE OR REPLACE FUNCTION public.create_company_for_signup(
  p_name TEXT,
  p_slug TEXT,
  p_plan TEXT DEFAULT 'starter'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_company_id UUID;
  v_tier TEXT;
BEGIN
  -- Validate user is authenticated
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Check user doesn't already have a company
  IF EXISTS (SELECT 1 FROM company_members WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already belongs to a company';
  END IF;

  -- Validate inputs
  IF nullif(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'Company name required';
  END IF;

  -- Map plan to tier
  v_tier := CASE lower(trim(p_plan))
    WHEN 'starter' THEN 'starter'
    WHEN 'professional' THEN 'professional'
    WHEN 'business' THEN 'business'
    WHEN 'enterprise' THEN 'enterprise'
    ELSE 'starter'
  END;

  -- Generate company ID
  v_company_id := gen_random_uuid();

  -- Create company
  INSERT INTO companies (id, name, slug, onboarding_state, base_subscription_tier)
  VALUES (v_company_id, trim(p_name), trim(p_slug), 'SUBSCRIPTION_ACTIVE', v_tier);

  -- Add user as admin
  INSERT INTO company_members (company_id, user_id, role, is_super_user)
  VALUES (v_company_id, v_user_id, 'admin', false);

  -- Create profile if not exists
  INSERT INTO profiles (user_id, display_name, email)
  VALUES (v_user_id, split_part(auth.email(), '@', 1), auth.email())
  ON CONFLICT (user_id) DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'company_id', v_company_id,
    'tier', v_tier
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_company_for_signup(TEXT, TEXT, TEXT) TO authenticated;
```

---

### 4. Flow State Management

**New State Variables:**
```javascript
let _signupMode = false;      // True when user is in signup flow (no session yet)
let _signupPlan = '';         // Plan from URL parameter
let _signupStep = 'account';  // Current signup step
```

**Modified `handleOnboardingRoute()`:**
```javascript
async function handleOnboardingRoute() {
  // Capture plan from URL
  storeOnboardingIntentFromUrl();
  _signupPlan = state._onboardingIntent?.plan || '';

  // Check if user is authenticated
  if (!SB.session) {
    // New signup flow - show account creation
    _signupMode = true;
    _signupStep = 'account';
    renderOnboardingStep('account');
    return true;
  }

  // User is authenticated - check if they have a company
  if (!SB.companyId) {
    // Authenticated but no company - show company creation
    _signupStep = 'company';
    renderOnboardingStep('company');
    return true;
  }

  // Existing flow continues...
  // ... rest of current handleOnboardingRoute logic
}
```

---

### 5. UI/UX Considerations

#### 5.1 Progress Bar Updates

**6-step progress:**
1. Account (signup only)
2. Company (signup only)
3. Profile
4. Locations
5. Team
6. Finish

**For existing users (already have company):**
- Skip steps 1-2
- Show 4-step progress as before

#### 5.2 Responsive Design

- All form fields full-width on mobile
- Password requirements shown below field
- Clear error messages

#### 5.3 Accessibility

- All inputs have labels
- Error states announced to screen readers
- Focus management on step transitions

---

## Security Considerations

1. **Password Requirements:**
   - Minimum 8 characters
   - Client-side validation + Supabase enforcement

2. **Rate Limiting:**
   - Supabase handles auth rate limiting
   - Consider additional limits on company creation

3. **Email Verification:**
   - Supabase sends confirmation email (local dev auto-confirms)
   - Production: require email verification before app access

4. **Slug Uniqueness:**
   - Company slugs must be unique
   - Handle collision gracefully with suffix

---

## Future Enhancements (Out of Scope)

1. **Stripe Integration:**
   - Payment collection before Step 5 completion
   - Trial period handling
   - Subscription management

2. **Social Auth:**
   - Google OAuth signup
   - Microsoft OAuth signup

3. **Invite Codes:**
   - Beta/waitlist flow with invite codes

---

## Dependencies

- Supabase Auth (signup, session management)
- Existing onboarding wizard (Steps 3-6)
- Google Places API (locations step)

---

## Rollback Plan

If issues arise:
1. Revert pricing page CTAs to non-functional
2. Hide signup steps via CSS/JS flag
3. Existing invite-only flow continues to work

---

## Success Metrics

1. **Signup Completion Rate:** % of users who complete all steps
2. **Drop-off by Step:** Identify friction points
3. **Time to First Location:** How quickly users add data
