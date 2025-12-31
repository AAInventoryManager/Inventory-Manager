# Jobs Model

## Definition
A Job represents a unit of planned work for a company that will consume inventory when completed. Jobs progress through a lifecycle that controls when inventory is reserved and consumed.

## Lifecycle States
- draft
- quoted
- approved
- in_progress (optional but recommended)
- completed
- voided

## Allowed Transitions
- draft -> quoted
- draft -> approved
- draft -> voided
- quoted -> approved
- quoted -> voided
- approved -> in_progress
- approved -> completed
- approved -> voided
- in_progress -> completed
- in_progress -> voided
- completed -> voided

## Transition Authority
- draft/quoted transitions (create/edit/quote): company member with job edit access, company admin, or super_user
- approve: company admin or super_user
- in_progress: company admin or super_user
- complete: company admin or super_user
- void: company admin or super_user

## Notes
- completed and voided are terminal except for allowed void transitions.
- Job approval is the point at which inventory reservation occurs (see JOBS_INVENTORY_MODEL.md).
- User feedback requirements apply during planning and approval (see JOBS_BOM_MODEL.md and JOBS_INVENTORY_MODEL.md).
