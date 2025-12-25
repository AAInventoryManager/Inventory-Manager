# Login & Sessions

Feature ID: inventory.auth.login

## Overview
Login provides secure access to Inventory Manager using email and password authentication. Sessions remain active until you sign out or your session expires.

## Tier Availability
- Starter
- Professional
- Business
- Enterprise

## How It Works
- Sign in with your account email and password.
- If your account is associated with a company, the app loads your company data after login.
- Signing out clears the session on the device.

## Security Expectations
- Each user should have their own account.
- Passwords are managed securely through the authentication provider.
- Sessions expire automatically if authentication tokens are invalidated.

## What It Does Not Support
- Shared or generic accounts.
- Password recovery outside the built-in reset flow.
- Anonymous or guest access.

## Support Expectations
Users may need help with login issues or session expiration. Support should confirm the account email and company membership status.
