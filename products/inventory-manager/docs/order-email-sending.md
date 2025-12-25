# Order Email Sending

Feature ID: inventory.orders.email_send

## Overview
Order Email Sending delivers the order content from the Order Builder to a recipient email address using the configured email provider.

## Tier Availability
- Business
- Enterprise

## How It Works
- Provide a recipient email and optional notes.
- The subject is generated as: `Purchase Order <Company PO Number or Internal PO ID> - <Company Name>`.
- The company name must be set to send; the system blocks sends when it is missing.
- The email includes the selected shipping address snapshot and order line items.
- A reply-to address is set to the signed-in user's email.

## Limitations
- Delivery depends on the configured email provider.
- Attachments and inline images are not supported.
- Only one recipient is supported per send.

## Support Expectations
Users may request help with delivery failures or sender configuration. Support should validate email provider settings and recipient formatting.
