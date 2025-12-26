# Metric Execution Engine (Runtime)

Authoritative source specs live in /Users/brandon/coding/Dev-Governance

This runtime engine must:
- Load a governed metric definition by metric_id
- Enforce pricing tier entitlement server-side
- Apply time semantics (AS_OF vs PERIOD_BASED)
- Execute formula deterministically
- Apply edge-case rules
- Return value + metadata (unit, precision, time_context, dimensions_applied)

All reports and dashboards must call this engine, never re-implement math.
