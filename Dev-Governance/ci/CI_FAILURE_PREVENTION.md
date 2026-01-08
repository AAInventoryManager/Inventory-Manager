# CI Failure Prevention Guide

## Purpose

This document captures recurring CI failure patterns and establishes prevention strategies. CI failures waste time, block deployments, and erode confidence in the test suite.

---

## Failure Pattern Registry

### 1. Migration Constraint Violations

**Symptoms:**
```
ERROR: new row for relation "X" violates check constraint "X_check" (SQLSTATE 23514)
```

**Root Cause:**
Migration applies `UPDATE` or `INSERT` while old constraints are still active, OR applies new constraint before data is migrated.

**Example (2026-01-08):**
```sql
-- WRONG: Constraint checked during UPDATE
ALTER TABLE companies ADD CONSTRAINT ... CHECK (environment_type IN ('production', 'test'));
UPDATE companies SET environment_type = 'test' WHERE ...;

-- CORRECT: Drop old constraint first, update data, add new constraint
ALTER TABLE companies DROP CONSTRAINT IF EXISTS companies_environment_type_check;
UPDATE companies SET environment_type = 'test' WHERE ...;
ALTER TABLE companies ADD CONSTRAINT companies_environment_type_check CHECK (...);
```

**Prevention:**
- [ ] Always `DROP CONSTRAINT` before data migration
- [ ] Always add new constraint AFTER data is transformed
- [ ] Wrap in transaction to ensure atomicity
- [ ] Test migrations locally against production-like data

---

### 2. Test User State Pollution

**Symptoms:**
```
Error: User X allegedly exists but not found in auth after paginated search
```

**Root Cause:**
Shared test database retains stale auth.users entries from previous runs. Supabase auth reports user "exists" but paginated lookup fails due to soft-delete or inconsistent state.

**Prevention:**
- [ ] Run test teardown BEFORE setup (defensive cleanup)
- [ ] Use deterministic test user IDs (UUIDs based on email hash)
- [ ] Add retry logic with exponential backoff for auth operations
- [ ] Consider isolated test database per CI run (more expensive)

**Quick Fix:**
Manually clean test users from auth if CI is stuck:
```sql
DELETE FROM auth.users WHERE email LIKE '%@test.local';
```

---

### 3. Migration Ordering Conflicts

**Symptoms:**
```
Found local migration files to be inserted before the last migration on remote database.
```

**Root Cause:**
New migration timestamp is earlier than already-applied migrations on remote.

**Prevention:**
- [ ] Always use current timestamp for new migrations: `YYYYMMDDHHMMSS`
- [ ] Check remote migration state before creating new migrations
- [ ] Use `supabase db pull` to sync migration history

**Quick Fix:**
Rename migration file with later timestamp, or use `--include-all` flag (with caution).

---

### 4. PostgREST Schema Cache Stale

**Symptoms:**
- RPC calls fail with "function does not exist"
- New columns not visible via REST API
- Tests pass locally but fail in CI

**Root Cause:**
PostgREST caches schema on startup. After `supabase db push`, schema changes aren't visible until PostgREST reloads.

**Prevention:**
- [ ] CI workflow already includes PostgREST restart + 15s sleep
- [ ] If still failing, increase sleep to 30s
- [ ] Consider using `pg_notify` for cache invalidation

---

### 5. Missing Environment Variables

**Symptoms:**
```
Error: Missing required environment variable: X
```

**Root Cause:**
New feature requires env var not set in CI secrets.

**Prevention:**
- [ ] Document all required env vars in `.env.example`
- [ ] Add env var to GitHub Secrets BEFORE merging PR
- [ ] Use explicit error messages that name the missing variable

---

### 6. Concurrent CI Run Conflicts

**Symptoms:**
- Intermittent test failures
- "duplicate key" errors
- Deadlocks or timeouts

**Root Cause:**
Multiple CI runs execute against same test database simultaneously.

**Current Mitigation:**
```yaml
concurrency:
  group: supabase-test-db
  cancel-in-progress: false
```

**Prevention:**
- [ ] Never remove the concurrency group
- [ ] Keep `cancel-in-progress: false` to avoid orphaned state
- [ ] Consider per-branch test databases for parallel PR testing

---

## Pre-Commit Checklist

Before pushing changes that affect CI:

### Migrations
- [ ] Tested migration locally with `supabase db push`
- [ ] Constraint changes follow DROP → UPDATE → ADD pattern
- [ ] Migration timestamp is after all existing migrations
- [ ] Rollback path documented (if applicable)

### Test Infrastructure
- [ ] New env vars added to GitHub Secrets
- [ ] Test fixtures updated if schema changed
- [ ] No hardcoded IDs that could conflict with production

### Edge Functions
- [ ] Deployed with `supabase functions deploy`
- [ ] All required secrets set via `supabase secrets set`
- [ ] Tested endpoint manually before relying on CI

---

## Recovery Procedures

### CI Stuck on Auth State

```bash
# Connect to test DB and clean auth state
psql $TEST_DATABASE_URL -c "DELETE FROM auth.users WHERE email LIKE '%@test.local';"
psql $TEST_DATABASE_URL -c "DELETE FROM public.profiles WHERE email LIKE '%@test.local';"
psql $TEST_DATABASE_URL -c "DELETE FROM public.company_members WHERE user_id NOT IN (SELECT id FROM auth.users);"

# Re-run CI
gh workflow run tests
```

### CI Stuck on Migration

```bash
# Check remote migration state
supabase db remote list

# If migration was partially applied, may need manual intervention
# Connect to test DB and check schema_migrations table
psql $TEST_DATABASE_URL -c "SELECT * FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 10;"
```

### Force PostgREST Reload

```bash
# Via Supabase Management API
curl -X POST \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/restart" \
  --data '{"services": ["postgrest"]}'
```

---

## Monitoring

### After Each CI Run
- Check if failure is new pattern or known issue
- If new pattern, add to this document
- If recurring, prioritize infrastructure fix

### Weekly Review
- Count CI failures by category
- Identify most frequent failure mode
- Allocate time to fix root cause

---

## Governance Checklist

- [ ] Migration follows constraint-safe pattern
- [ ] Test teardown runs before setup
- [ ] New env vars documented and set
- [ ] PostgREST cache invalidation considered
- [ ] Concurrency controls preserved
