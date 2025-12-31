# Jobs Invariants

- Jobs do NOT change inventory in draft or quoted states.
- Job approval is blocked if available inventory < planned BOM requirements.
- Reserved inventory cannot be edited directly.
- Reserved inventory is derived solely from approved jobs.
- Inventory is decremented only by actual consumption on completion.
- Completing a job releases all reservations for that job.
- Voiding a job releases reservations and reverses consumption if applicable.
