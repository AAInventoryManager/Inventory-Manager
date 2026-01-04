# Jobs BOM Model

## Planned BOM Definition
The planned Bill of Materials (BOM) defines the expected inventory required for a Job.

### Fields
- item_id
- qty_planned

## Behavior
- The planned BOM has no inventory impact in draft or quoted states.
- Real-time on_hand checks are performed during planning using current physical counts.
- Availability is a derived concept (on_hand - reserved) and is not shown as a UI label in Jobs views.
- The planned BOM is the basis for approval checks and reservation calculations.
- BOM edits are allowed in draft and quoted states. Changes after approval require re-approval and reservation recalculation.

## User Feedback Requirements
- During job planning, the system must show:
  - On Hand quantity per item
  - Incoming (Not Yet Received) quantity when shown
  - Shortfall amount if planned exceeds On Hand

## UI Terminology and Read-Only Context
- UI labels are descriptive and do not mutate state.
- Job-scoped inventory views are read-only.
- Allocation and availability are derived concepts and will be computed once implemented; Jobs UI shows On Hand and Incoming (Not Yet Received) only.
