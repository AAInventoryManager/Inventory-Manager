# Metric Execution Contract

Purpose:
Defines how a governed metric is executed at runtime within the application.

## Inputs
- metric_id (string)
- requesting_user
- requesting_user_tier
- context:
  - date_range OR as_of_date
  - filters (item, category, location, etc.)

## Execution Rules
1. Load metric definition by metric_id.
2. Verify requesting_user_tier >= metric.tier.
3. Resolve time semantics:
   - AS_OF: compute snapshot at as_of_date.
   - PERIOD_BASED: compute over period_start → period_end.
4. Execute metric formula exactly as defined.
5. Apply all edge case handling rules.
6. Return value with precision as defined.

## Forbidden Behavior
- Do not compute metrics for unauthorized tiers.
- Do not modify formulas.
- Do not infer missing inputs.
- Do not return partial or approximated values.

## Security
- Client-provided tier values are ignored.
- Tier entitlement is derived exclusively from server-trusted identity.

## Output
- metric_id
- value
- unit
- precision
- time_context
- dimensions_applied

## Error Conditions
- UnauthorizedTier
- MissingInput
- InvalidTimeContext
- MetricNotFound
