# Jobs Inventory Model

## Inventory Quantities
- on_hand
- reserved
- available = on_hand - reserved (derived, not a Jobs UI label)

## Reservations
- Reservations occur on job approval only.
- Approved jobs reserve qty_planned for each BOM line.
- Reserved inventory is derived from approved jobs and cannot be edited directly.

## Consumption
- Inventory consumption occurs on job completion using actuals.
- on_hand is decremented by qty_actual per item.
- Completing a job releases all reservations for that job.

## Variance Handling
- If qty_actual < qty_planned, the remainder is released back to derived availability (on_hand - reserved).
- If qty_actual > qty_planned, the additional quantity is consumed from on_hand at completion.
- Completion is blocked if on_hand is insufficient to cover actual consumption.

## Job Void Behavior
- Voiding a job releases any reservations.
- If consumption occurred, voiding reverses the consumption by restoring on_hand.

## User Feedback Requirements
- On approval attempt, the system must clearly list:
  - Items blocking approval
  - Required quantities to order

## UI Terminology and Read-Only Context
- UI labels are descriptive and do not mutate state.
- Job-scoped inventory views are read-only.
- Availability and allocation are derived concepts and will be computed once implemented; Jobs UI shows On Hand and Incoming (Not Yet Received) only.
