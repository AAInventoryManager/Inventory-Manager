# Test Company Naming Convention

## Purpose
Define a consistent naming convention for test companies to enable easy identification, filtering, and bulk operations on non-production data.

## Naming Convention

### Required Prefix
All test companies created by developers or automated systems (e.g., Playwright E2E tests) **must** use the prefix:

```
#Test_
```

### Format
```
#Test_<DescriptiveName>
```

### Examples
- `#Test_E2E_LoginFlow`
- `#Test_Playwright_InventorySync`
- `#Test_Dev_SeedingScenario`
- `#Test_QA_EdgeCases`

## Scope

### Companies That Must Use This Convention
1. **Playwright E2E test companies** - All companies created by automated test scripts
2. **Developer test companies** - Companies created for manual development testing
3. **QA test companies** - Companies created for quality assurance testing
4. **Demo companies** - Companies created for internal demos or training

### Companies That Must NOT Use This Convention
1. **Production customer companies** - Real customer companies
2. **Seeded production companies** - Companies seeded from real customer data for support purposes

## Environment Type

Test companies using the `#Test_` prefix should also have:
- `environment_type = 'test'`

This combination allows for:
1. Visual identification via the prefix in company names
2. Database-level filtering via `environment_type`

## Benefits

### Sorting and Filtering
- Companies prefixed with `#` sort to the top alphabetically in most views
- Easy visual distinction from production companies
- Simple SQL/UI filtering: `WHERE name LIKE '#Test_%'`

### Bulk Operations
Developers can perform bulk operations on test companies:
```sql
-- Example: Delete all test companies older than 30 days
DELETE FROM companies
WHERE name LIKE '#Test_%'
  AND environment_type = 'test'
  AND created_at < NOW() - INTERVAL '30 days';
```

### Metrics Exclusion
Test companies are automatically excluded from platform metrics:
- Platform dashboard counts only `environment_type = 'production'`
- The `#Test_` prefix provides additional visual confirmation

## Implementation Requirements

### Playwright E2E Tests
All E2E test fixtures creating companies must:
1. Prefix company names with `#Test_`
2. Set `environment_type = 'test'`
3. Include a descriptive suffix (e.g., test scenario name)

Example fixture pattern:
```typescript
const testCompany = await createTestCompany({
  name: `#Test_E2E_${testScenarioName}`,
  environment_type: 'test'
});
```

### Manual Provisioning
When super_users create test companies via the Provision Company UI:
1. Start the company name with `#Test_`
2. Select "Test" from the Environment Type dropdown

## Cleanup Policy

Test companies (`#Test_*` with `environment_type = 'test'`) may be:
- Manually deleted by super_users at any time
- Subject to automated cleanup scripts (future implementation)
- Excluded from backup retention policies

## Migration Notes

### Existing Test Companies
Existing test companies that do not follow this convention should be:
1. Renamed to include the `#Test_` prefix, OR
2. Deleted if no longer needed

### Removed Features
The following features have been deprecated in favor of this naming convention:
- `cleanup_eligible` column (removed)
- `internal_test`, `demo`, `sandbox` environment types (consolidated to `test`)

## Governance

This naming convention is **mandatory** for all new test company creation as of the implementation date. Violations should be corrected during code review.
