#!/usr/bin/env python3

import os
import sys
import math

try:
    import yaml
except Exception:
    print("ERROR: PyYAML is not installed.")
    print("Install with: python3 -m pip install pyyaml")
    sys.exit(1)

ROOT = "/Users/brandon/coding/Dev-Governance"
SCHEMA_PATH = os.path.join(ROOT, "METRIC_REGISTRY_SCHEMA.yaml")

# -------------------------
# Argument handling
# -------------------------
if len(sys.argv) != 2:
    print("Usage:")
    print("  validate_metric.py <path-to-metric-yaml>")
    sys.exit(1)

METRIC_PATH = os.path.abspath(sys.argv[1])

if not os.path.exists(SCHEMA_PATH):
    print(f"ERROR: Schema not found: {SCHEMA_PATH}")
    sys.exit(1)

if not os.path.exists(METRIC_PATH):
    print(f"ERROR: Metric file not found: {METRIC_PATH}")
    sys.exit(1)

# -------------------------
# Helpers
# -------------------------
def load_yaml(path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def edge_case_to_text(ec):
    if isinstance(ec, str):
        return ec
    if isinstance(ec, dict):
        return " ".join(f"{k} {v}" for k, v in ec.items())
    return str(ec)

# -------------------------
# Load files
# -------------------------
schema = load_yaml(SCHEMA_PATH)
metric = load_yaml(METRIC_PATH)

errors = []

# -------------------------
# 1) Required fields
# -------------------------
for field in schema.get("required_fields", []):
    if field not in metric or metric.get(field) in (None, "", [], {}):
        errors.append(f"Missing or empty required field: {field}")

# -------------------------
# 2) Tier validation
# -------------------------
allowed_tiers = set(schema.get("allowed_tiers", []))
tier = metric.get("tier")
if tier not in allowed_tiers:
    errors.append(f"Invalid tier '{tier}'. Allowed: {sorted(allowed_tiers)}")

# -------------------------
# 3) Time semantics
# -------------------------
ts = metric.get("time_semantics", {})
allowed_ts = set(schema.get("time_semantics_rules", {}).get("allowed_types", []))
ts_type = ts.get("type")

if ts_type not in allowed_ts:
    errors.append(f"Invalid time_semantics.type '{ts_type}'")

dates = ts.get("required_dates", [])
required_by_type = schema.get("time_semantics_rules", {}).get("required_dates_by_type", {})
expected_dates = required_by_type.get(ts_type) if isinstance(required_by_type, dict) else None

if expected_dates:
    if not isinstance(dates, list):
        errors.append("time_semantics.required_dates must be a list")
    else:
        expected_set = set(expected_dates)
        if set(dates) != expected_set or len(dates) != len(expected_dates):
            errors.append(
                f"time_semantics.required_dates must match {sorted(expected_set)}"
            )
else:
    if not isinstance(dates, list) or len(dates) < 2:
        errors.append("time_semantics.required_dates must include start and end")

# -------------------------
# 4) Test rules
# -------------------------
tests = metric.get("tests", [])
min_tests = schema.get("test_rules", {}).get("minimum_test_cases", 2)

if not isinstance(tests, list) or len(tests) < min_tests:
    errors.append(f"Insufficient tests (found {len(tests)}, require {min_tests})")
else:
    for t in tests:
        if "expected_output" not in t:
            errors.append(f"Test missing expected_output: {t.get('name','<unnamed>')}")

# -------------------------
# 5) Edge cases
# -------------------------
edge_cases = metric.get("edge_cases", [])
min_edges = schema.get("edge_case_rules", {}).get("minimum_count", 1)

if not isinstance(edge_cases, list) or len(edge_cases) < min_edges:
    errors.append("Insufficient edge_cases")

division_rule = schema.get("edge_case_rules", {}).get("require_division_by_zero_handling", False)
require_division_handling = False

if division_rule is True:
    require_division_handling = True
elif division_rule == "when_math_operations_includes_division":
    operations = metric.get("math_operations", [])
    if isinstance(operations, list):
        normalized = {str(op).strip().lower() for op in operations}
        require_division_handling = "division" in normalized

if require_division_handling:
    edge_text = " ".join(edge_case_to_text(ec) for ec in edge_cases).lower()
    if "zero" not in edge_text and "division" not in edge_text:
        errors.append("edge_cases must explicitly mention division-by-zero handling")

# -------------------------
# 6) Audit fields
# -------------------------
audit = metric.get("audit", {})
for field in ("created_by", "approved_by", "approval_date"):
    if field not in audit or audit.get(field) in (None, ""):
        errors.append(f"Missing or empty audit.{field}")

# -------------------------
# 7) Metric-specific math validation
# -------------------------
math_failures = []

if metric.get("metric_id") == "INVENTORY_TURNOVER":

    def compute_inventory_turnover(inputs):
        cogs = inputs.get("COGS")
        inv_begin = inputs.get("InventoryBegin")
        inv_end = inputs.get("InventoryEnd")

        if None in (cogs, inv_begin, inv_end):
            return None

        avg_inventory = (inv_begin + inv_end) / 2.0

        if avg_inventory == 0:
            return None

        if cogs == 0:
            return 0.0

        return cogs / avg_inventory

    for t in tests:
        name = t.get("name", "<unnamed>")
        inputs = t.get("inputs", {})
        expected = t.get("expected_output")
        actual = compute_inventory_turnover(inputs)

        if expected is None:
            if actual is not None:
                math_failures.append(f"{name}: expected NULL, got {actual}")
        else:
            if actual is None or abs(actual - float(expected)) > 0.01:
                math_failures.append(f"{name}: expected {expected}, got {actual}")

# -------------------------
# Output
# -------------------------
print("=== Metric Governance Validation ===")
print(f"Schema: {SCHEMA_PATH}")
print(f"Metric: {METRIC_PATH}\n")

if errors:
    print("VALIDATION: FAIL")
    for e in errors:
        print(" -", e)
else:
    print("VALIDATION: PASS")

if math_failures:
    print("\nMATH TESTS: FAIL")
    for m in math_failures:
        print(" -", m)
else:
    print("\nMATH TESTS: PASS")

print("\nIMPLEMENTATION ASSUMPTIONS TO CONFIRM (Phase 2):")
for name, var in metric.get("variables", {}).items():
    print(
        f" - {name}: tables={var.get('source_tables')} "
        f"fields={var.get('source_fields')} "
        f"aggregation={var.get('aggregation')}"
    )

if errors or math_failures:
    sys.exit(1)

print("\nValidation complete.")
