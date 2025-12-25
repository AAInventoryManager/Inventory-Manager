# Order Builder

Feature ID: inventory.orders.cart

## Overview
The Order Builder lets users assemble a purchase order from selected inventory items, adjust quantities, and preview the outgoing order before sending.

## Tier Availability
- Business
- Enterprise

## How It Works
- Select inventory items and open the order builder.
- Enter an optional Company PO Number; the system generates an Internal PO ID.
- Choose a company-managed shipping address (admins or users with shipping permissions can manage addresses).
- Add optional notes; the subject line is generated from the PO identifier and company name.
- Preview the order content before sending it.

## Limitations
- Does not create a formal purchase order with approvals.
- No vendor catalog or item pricing lookup.
- Shipping addresses are managed at the company level; users without permission can only select existing addresses.
- Internal PO IDs are system-generated and cannot be edited after submission.
- Order drafts are limited to the current session until submitted.

## Support Expectations
Users may need help understanding the cart workflow or adjusting quantities. Support should confirm order drafts are email-based and not a procurement system.
