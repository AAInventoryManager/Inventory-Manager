# Snapshots UI

Feature ID: inventory.snapshots.ui

## Overview
The Snapshots UI provides a read-only view of historical inventory snapshots. It lets authorized users browse snapshot metadata and preview the stored item list without modifying data.

## Tier Availability
- Business
- Enterprise

## How It Works
- The UI lists snapshots for the active company using the existing snapshot RPCs.
- Selecting a snapshot shows a preview of items captured at that point in time.
- No create, restore, or delete actions are exposed in the UI during Phase 1B.

## Limitations
- Read-only only; snapshots must be created/restored through admin workflows outside the UI.
- Preview data shows item IDs and stored fields as captured; no live joins for category/location names.
- Snapshot previews are capped for performance.

## Support Expectations
This feature may generate questions about snapshot meaning and preview content. Support should confirm scope (read-only) and direct admins to approved workflows for create/restore.
