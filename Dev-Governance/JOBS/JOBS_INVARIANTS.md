# Jobs Invariants

- Jobs do NOT change inventory in draft or quoted states.
- Job approval is blocked if derived availability (on_hand - reserved) < planned BOM requirements.
- Reserved inventory cannot be edited directly.
- Reserved inventory is derived solely from approved jobs.
- Inventory is decremented only by actual consumption on completion.
- Completing a job releases all reservations for that job.
- Voiding a job releases reservations and reverses consumption if applicable.

## UI Terminology and Read-Only Context
- UI labels are descriptive and do not mutate state.
- Job-scoped inventory views are read-only.
- Availability and allocation are derived concepts and will be computed once implemented; Jobs UI shows On Hand and Incoming (Not Yet Received) only.

## Job Readiness (Derived)
- Job readiness is derived and never user-editable.
- A job is Ready to Staff iff:
  - status = approved
  - no active shortfalls exist for the job
  - every BOM line is fully allocated for the job (allocated >= qty_planned)
- Reasons when not ready are deterministic and machine-readable:
  - job_not_approved
  - shortfall_exists
  - allocation_incomplete
