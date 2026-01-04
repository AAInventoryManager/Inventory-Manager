# Phase 2 – Metric Implementation Order

Rule:
Metrics must be implemented in this order. A metric may not begin
implementation until the previous metric has passed validation,
tests, and entitlement enforcement.

## Execution Order

1. INVENTORY_TURNOVER
   Reason: Foundation metric. Validates COGS, inventory snapshots,
   period math, and tier enforcement.

2. DAYS_INVENTORY_OUTSTANDING
   Reason: Builds directly on Inventory Turnover math and inventory
   averaging logic.

3. INVENTORY_AGING
   Reason: Introduces time-bucket logic and receipt-date semantics.

4. FAST_SLOW_DEAD_STOCK
   Reason: Reuses movement history and aging outputs.

5. ABC_CLASSIFICATION
   Reason: Depends on annualized usage and cost aggregation.

## Enforcement
- No parallel metric development
- No metric skipping
- No Tier 3 metrics in Phase 2

Phase 2 Exit Condition:
All Tier 2 metrics implemented, tested, and tier-gated.
