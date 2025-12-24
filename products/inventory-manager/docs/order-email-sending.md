# Order Email Sending

Feature ID: inventory.orders.email_send

## Overview
Order Email Sending delivers the order content from the Order Builder to a recipient email address using the configured email provider.

## Tier Availability
- Business
- Enterprise

## How It Works
- Provide a recipient email, subject, and optional notes.
- The system sends the order summary as a formatted email.
- A reply-to address is set to the signed-in user when available.

## Limitations
- Delivery depends on the configured email provider.
- Attachments and inline images are not supported.
- Only one recipient is supported per send.

## Support Expectations
Users may request help with delivery failures or sender configuration. Support should validate email provider settings and recipient formatting.
