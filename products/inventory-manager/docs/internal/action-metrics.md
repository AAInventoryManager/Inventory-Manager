# Action Metrics

Feature ID: inventory.metrics.action_metrics

## Overview
Action Metrics is an internal aggregation table used to power metrics dashboards and audit-style reporting. It tracks daily counts for inventory actions.

## Tier Availability
- Professional
- Business
- Enterprise

## How It Works
- Metrics are written by triggers and RPCs during inventory actions.
- Dashboard RPCs aggregate data by date and action type.
- Direct table access is limited to super users and tier-qualified companies.

## Limitations
- Metrics are aggregated daily, not real time.
- Data coverage depends on which actions are instrumented.
- Backfilled metrics are not guaranteed for historical data.

## Support Expectations
None. This is internal-only documentation.
