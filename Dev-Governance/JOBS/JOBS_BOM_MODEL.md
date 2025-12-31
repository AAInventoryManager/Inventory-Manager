# Jobs BOM Model

## Planned BOM Definition
The planned Bill of Materials (BOM) defines the expected inventory required for a Job.

### Fields
- item_id
- qty_planned

## Behavior
- The planned BOM has no inventory impact in draft or quoted states.
- Real-time availability checks are performed during planning using current available quantities.
- The planned BOM is the basis for approval checks and reservation calculations.
- BOM edits are allowed in draft and quoted states. Changes after approval require re-approval and reservation recalculation.

## User Feedback Requirements
- During job planning, the system must show:
  - Available quantity per item
  - Shortfall amount if insufficient
