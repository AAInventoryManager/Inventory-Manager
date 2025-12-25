# Low Stock Alerts

Feature ID: inventory.inventory.low_stock

## Overview
Low Stock Alerts highlight items that have fallen at or below their low stock threshold using LED indicators in the inventory table and reports.

## Tier Availability
- Starter
- Professional
- Business
- Enterprise

## How It Works
- Each item can have its own low stock threshold.
- If an item does not define a threshold, the global low stock threshold from Profile Settings is used.
- Items at or below the threshold are flagged as low stock in the UI.
- Users can hide low stock LED indicators from Profile Settings.

## What It Does Not Do
- Does not place orders or trigger automation.
- Does not send email, SMS, or push notifications.
- Does not update reorder settings automatically.

## Limitations
- Thresholds are integer values and apply per item.
- Low stock status updates when inventory quantities change.
- Indicators are visual only and rely on UI access.

## Support Expectations
Users may ask why an item is flagged or not flagged. Support should confirm the per-item threshold and the global default in Profile Settings.
