# Low Stock API

Feature ID: inventory.reports.low_stock_api

## Overview
The Low Stock API returns inventory items at or below their reorder thresholds. It is designed for integrations and automated purchasing workflows.

## Tier Availability
- Professional
- Business
- Enterprise

## How It Works
- The API queries low-stock items for the authenticated user’s company.
- Items are classified by urgency (critical when quantity is zero, warning otherwise).
- Filters support category, location, urgency, and pagination.

## Limitations
- Only items with a reorder threshold are included.
- Results are scoped to a single company per user (Phase 1 constraint).
- Total counts are estimated when paginating.

## Support Expectations
Support may be asked about missing items or access errors. Confirm tier eligibility, item thresholds, and permissions before troubleshooting.
