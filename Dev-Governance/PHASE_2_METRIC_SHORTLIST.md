# Phase 2 – Metrics Foundation (Authoritative Shortlist)

Purpose:
Establish the first governed, tier-gated inventory metrics using the Metric Registry.
Phase 2 focuses on analytical insight (not forecasting or optimization).

## Tier 2 Metrics (Primary Upgrade Drivers)

1. INVENTORY_TURNOVER
   Description: Measures how many times inventory is sold and replaced over a period.
   Category: Efficiency
   Priority: P0

2. DAYS_INVENTORY_OUTSTANDING
   Description: Average number of days inventory is held before being sold.
   Category: Liquidity
   Priority: P0

3. INVENTORY_AGING
   Description: Classifies on-hand inventory into age buckets based on receipt date.
   Category: Risk
   Priority: P0

4. FAST_SLOW_DEAD_STOCK
   Description: Categorizes SKUs based on movement velocity thresholds.
   Category: Optimization
   Priority: P1

5. ABC_CLASSIFICATION
   Description: Ranks SKUs by annual consumption value and assigns A/B/C classes.
   Category: Prioritization
   Priority: P1

## Tier 3 Metrics (Deferred – Not in Phase 2)

- GROSS_MARGIN_RETURN_ON_INVENTORY (GMROI)
- CARRYING_COST_OF_INVENTORY
- CASH_TO_CASH_CYCLE_TIME
- INVENTORY_AS_PERCENT_OF_ASSETS
- PURCHASE_PRICE_VARIANCE

## Explicit Exclusions for Phase 2
- Forecasting metrics
- Optimization recommendations
- AI-derived insights
- Cash-flow KPIs
- Reserve and write-down accounting

Phase Exit Criteria:
- All Tier 2 metrics defined using metric_definition.yaml
- All metrics pass schema validation
- All metric math validated with test vectors
- Tier enforcement verified at query level
