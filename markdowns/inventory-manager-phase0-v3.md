# Inventory Manager: Phase 0 — Testing Infrastructure
## Automated Testing Setup for Multi-Tenant SaaS

**Version:** 3.0  
**Date:** December 2024  
**Prerequisite:** Run BEFORE Phase 1 implementation  
**Stack:** Supabase + Vanilla JS + Vitest + Playwright  
**Aligned with:** Phase 1 v6

---

## Table of Contents

1. [Overview](#overview)
2. [Testing Strategy](#testing-strategy)
3. [Project Structure](#project-structure)
4. [Installation & Setup](#installation--setup)
5. [Test Configuration Files](#test-configuration-files)
6. [Database Testing](#database-testing)
7. [API/RPC Testing](#apirpc-testing)
8. [Frontend Unit Testing](#frontend-unit-testing)
9. [End-to-End Testing](#end-to-end-testing)
10. [Test Fixtures & Seed Data](#test-fixtures--seed-data)
11. [CI/CD Pipeline](#cicd-pipeline)
12. [Running Tests](#running-tests)

---

## Overview

### Why Test First?

Phase 1 introduces critical security features (RLS, RBAC, multi-tenancy). A single bug could:
- Expose Company A's data to Company B
- Allow privilege escalation (member → admin)
- Permanently delete data (bypassing soft delete)

Testing infrastructure ensures these bugs are caught before production.

### Testing Pyramid

```
                    ┌───────────────┐
                    │     E2E       │  5-10 tests
                    │  (Playwright) │  Critical paths only
                    ├───────────────┤
                    │  Integration  │  50-70 tests
                    │  (API + DB)   │  RPC functions, RLS, triggers
                    ├───────────────┤
                    │     Unit      │  50+ tests
                    │   (Vitest)    │  Utility functions
                    └───────────────┘
```

### Coverage Targets

| Layer | Target | Priority |
|-------|--------|----------|
| RLS Policies | 95%+ | 🔴 Critical |
| RPC Functions | 90%+ | 🔴 Critical |
| Trigger Protection | 100% | 🔴 Critical |
| Security Tests | 100% | 🔴 Critical |
| Frontend Utils | 70%+ | 🟡 Medium |
| E2E Happy Paths | Key flows | 🟡 Medium |

---

## Testing Strategy

### What We're Testing

| Category | Examples | Tool |
|----------|----------|------|
| **RLS Policies** | Cross-tenant isolation, deleted row visibility | Vitest + Supabase client |
| **RPC Functions** | `soft_delete_item`, `soft_delete_order`, `invite_user`, `get_my_permissions` | Vitest + Supabase client |
| **Trigger Protection** | company_id immutability, cross-tenant FK validation | Vitest + Supabase client |
| **RLS Guards** | deleted_at protection, INSERT guards | Vitest + Supabase client |
| **Security** | Privilege escalation, SECURITY DEFINER abuse | Vitest + Supabase client |
| **Frontend Logic** | `canDelete()`, `formatNumber()`, `parseCSVLine()` | Vitest + jsdom |
| **E2E Flows** | Login, CRUD operations, invitation acceptance | Playwright |

### Test User Matrix

We'll create test users for each role to verify permissions:

| User | Email | Role | Company | Purpose |
|------|-------|------|---------|---------|
| Super User | super@test.local | super_user | Test Co | Platform-wide access |
| Admin | admin@test.local | admin | Test Co | Company admin |
| Member | member@test.local | member | Test Co | Standard user |
| Viewer | viewer@test.local | viewer | Test Co | Read-only |
| Other Admin | other@test.local | admin | Other Co | Cross-tenant tests |

---

## Project Structure

```
inventory-manager/
├── src/
│   ├── js/
│   │   ├── app.js              # Main application
│   │   ├── supabase.js         # Supabase client
│   │   └── utils.js            # Utility functions (extracted for testing)
│   └── index.html
├── supabase/
│   ├── migrations/
│   │   ├── 001_initial.sql
│   │   └── 002_phase1_multitenancy.sql
│   └── seed.sql                # Test seed data
├── tests/
│   ├── setup/
│   │   ├── global-setup.ts     # Create test users before all tests
│   │   ├── global-teardown.ts  # Cleanup after all tests
│   │   └── test-utils.ts       # Shared helpers
│   ├── fixtures/
│   │   ├── users.ts            # Test user definitions
│   │   ├── companies.ts        # Test company data
│   │   └── inventory.ts        # Test inventory items
│   ├── unit/
│   │   ├── utils.test.ts       # Frontend utility tests
│   │   └── permissions.test.ts # Permission helper tests
│   ├── integration/
│   │   ├── rls/
│   │   │   ├── inventory-items.test.ts
│   │   │   ├── company-members.test.ts
│   │   │   └── cross-tenant.test.ts
│   │   ├── rpc/
│   │   │   ├── soft-delete.test.ts
│   │   │   ├── order-soft-delete.test.ts  # NEW: Order delete/restore
│   │   │   ├── invitations.test.ts
│   │   │   ├── snapshots.test.ts
│   │   │   └── permissions.test.ts
│   │   └── security/
│   │       ├── privilege-escalation.test.ts
│   │       ├── hard-delete-blocked.test.ts
│   │       ├── definer-abuse.test.ts
│   │       ├── company-id-immutable.test.ts  # NEW: Trigger protection
│   │       ├── cross-tenant-fk.test.ts       # NEW: FK validation
│   │       └── deleted-at-rls.test.ts        # NEW: RLS protection
│   └── e2e/
│       ├── auth.spec.ts
│       ├── inventory-crud.spec.ts
│       ├── permissions-ui.spec.ts
│       └── invitations.spec.ts
├── vitest.config.ts
├── playwright.config.ts
├── package.json
└── .github/
    └── workflows/
        └── test.yml
```

---

## Installation & Setup

### Step 1: Initialize npm (if not already)

```bash
cd inventory-manager
npm init -y
```

### Step 2: Install Testing Dependencies

```bash
# Core testing
npm install -D vitest @vitest/coverage-v8

# Supabase client for tests
npm install -D @supabase/supabase-js

# DOM testing (for frontend utils)
npm install -D jsdom @testing-library/dom

# E2E testing
npm install -D @playwright/test

# TypeScript support
npm install -D typescript @types/node tsx

# Utilities
npm install -D dotenv
```

### Step 3: Create Environment Files

```bash
# .env.test (for local testing)
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=your-local-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-local-service-role-key
TEST_USER_PASSWORD=TestPassword123!

# .env.test.ci (for CI - uses separate test project)
SUPABASE_URL=https://your-test-project.supabase.co
SUPABASE_ANON_KEY=your-test-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-test-service-role-key
TEST_USER_PASSWORD=TestPassword123!
```

### Step 4: Add Scripts to package.json

```json
{
  "scripts": {
    "dev": "vite",
    "test": "vitest",
    "test:run": "vitest run",
    "test:unit": "vitest run tests/unit",
    "test:integration": "vitest run tests/integration",
    "test:coverage": "vitest run --coverage",
    "test:e2e": "playwright test",
    "test:e2e:ui": "playwright test --ui",
    "test:e2e:headed": "playwright test --headed",
    "test:setup": "npx tsx tests/setup/global-setup.ts",
    "test:teardown": "npx tsx tests/setup/global-teardown.ts",
    "test:all": "npm run test:run && npm run test:e2e",
    "supabase:start": "supabase start",
    "supabase:stop": "supabase stop",
    "supabase:reset": "supabase db reset"
  }
}
```

### Step 5: Install Playwright Browsers

```bash
npx playwright install chromium
```

---

## Test Configuration Files

### vitest.config.ts

```typescript
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Global test settings
    globals: true,
    
    // Environment for DOM tests
    environment: 'jsdom',
    
    // Setup files run before each test file
    setupFiles: ['./tests/setup/test-utils.ts'],
    
    // Global setup/teardown
    globalSetup: './tests/setup/global-setup.ts',
    globalTeardown: './tests/setup/global-teardown.ts',
    
    // Test file patterns
    include: [
      'tests/unit/**/*.test.ts',
      'tests/integration/**/*.test.ts'
    ],
    
    // Exclude E2E (handled by Playwright)
    exclude: ['tests/e2e/**', 'node_modules/**'],
    
    // Timeouts
    testTimeout: 30000,  // 30s for DB operations
    hookTimeout: 60000,  // 60s for setup
    
    // Coverage
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      reportsDirectory: './coverage',
      exclude: [
        'node_modules/**',
        'tests/**',
        '**/*.config.*'
      ],
      // Thresholds
      thresholds: {
        statements: 70,
        branches: 70,
        functions: 70,
        lines: 70
      }
    },
    
    // Reporter
    reporters: ['verbose'],
    
    // Pool settings for isolation
    pool: 'forks',
    poolOptions: {
      forks: {
        singleFork: true  // Run tests sequentially to avoid DB conflicts
      }
    }
  }
})
```

### playwright.config.ts

```typescript
import { defineConfig, devices } from '@playwright/test'
import dotenv from 'dotenv'

// Load test environment
dotenv.config({ path: '.env.test' })

export default defineConfig({
  testDir: './tests/e2e',
  
  // Run tests sequentially (shared test data)
  fullyParallel: false,
  workers: 1,
  
  // Fail fast in CI
  forbidOnly: !!process.env.CI,
  
  // Retries
  retries: process.env.CI ? 2 : 0,
  
  // Reporter
  reporter: [
    ['html', { outputFolder: 'playwright-report' }],
    ['list']
  ],
  
  // Shared settings
  use: {
    baseURL: process.env.TEST_APP_URL || 'http://localhost:5173',
    
    // Capture on failure
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',
    
    // Timeouts
    actionTimeout: 10000,
    navigationTimeout: 30000
  },
  
  // Browser projects
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] }
    }
    // Add more browsers as needed:
    // { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    // { name: 'mobile', use: { ...devices['iPhone 13'] } },
  ],
  
  // Start Vite dev server before tests
  webServer: {
    command: 'npm run dev',  // Vite dev server
    url: 'http://localhost:5173',
    reuseExistingServer: !process.env.CI,
    timeout: 120000
  },
  
  // Global setup/teardown
  globalSetup: './tests/setup/playwright-setup.ts',
  globalTeardown: './tests/setup/playwright-teardown.ts'
})
```

### tsconfig.json (for TypeScript tests)

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": ".",
    "types": ["vitest/globals", "node"]
  },
  "include": ["tests/**/*", "src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

---

## Database Testing

### tests/setup/test-utils.ts

```typescript
import { createClient, SupabaseClient } from '@supabase/supabase-js'
import dotenv from 'dotenv'

// Load environment
dotenv.config({ path: '.env.test' })

// Environment variables
export const SUPABASE_URL = process.env.SUPABASE_URL!
export const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY!
export const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!
export const TEST_PASSWORD = process.env.TEST_USER_PASSWORD || 'TestPassword123!'

// Service role client (bypasses RLS - for setup/teardown only)
export const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
})

// Create authenticated client for a specific user
export async function createAuthenticatedClient(email: string, password: string): Promise<SupabaseClient> {
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false }
  })
  
  const { data, error } = await client.auth.signInWithPassword({ email, password })
  
  if (error) {
    throw new Error(`Failed to authenticate ${email}: ${error.message}`)
  }
  
  return client
}

// Test user emails (defined in fixtures)
export const TEST_USERS = {
  SUPER: 'super@test.local',
  ADMIN: 'admin@test.local',
  MEMBER: 'member@test.local',
  VIEWER: 'viewer@test.local',
  OTHER_ADMIN: 'other@test.local'
}

// Test company slugs
export const TEST_COMPANIES = {
  MAIN: 'test-company',
  OTHER: 'other-company'
}

// Cached clients (created once per test file)
let clientCache: Record<string, SupabaseClient> = {}

export async function getClient(userType: keyof typeof TEST_USERS): Promise<SupabaseClient> {
  if (!clientCache[userType]) {
    clientCache[userType] = await createAuthenticatedClient(TEST_USERS[userType], TEST_PASSWORD)
  }
  return clientCache[userType]
}

// Clear client cache between test files
export function clearClientCache() {
  clientCache = {}
}

// Helper to get company ID by slug
export async function getCompanyId(slug: string): Promise<string> {
  const { data, error } = await adminClient
    .from('companies')
    .select('id')
    .eq('slug', slug)
    .single()
  
  if (error) throw new Error(`Company not found: ${slug}`)
  return data.id
}

// Helper to get user ID by email
export async function getUserId(email: string): Promise<string> {
  const { data, error } = await adminClient
    .from('profiles')
    .select('id')
    .eq('email', email)
    .single()
  
  if (error) throw new Error(`User not found: ${email}`)
  return data.id
}
```

### tests/setup/global-setup.ts

```typescript
import { adminClient, TEST_PASSWORD, TEST_USERS, TEST_COMPANIES } from './test-utils'

interface TestUser {
  email: string
  role: 'admin' | 'member' | 'viewer'
  company: string
  isSuperUser?: boolean
}

const testUsers: TestUser[] = [
  { email: TEST_USERS.SUPER, role: 'admin', company: TEST_COMPANIES.MAIN, isSuperUser: true },
  { email: TEST_USERS.ADMIN, role: 'admin', company: TEST_COMPANIES.MAIN },
  { email: TEST_USERS.MEMBER, role: 'member', company: TEST_COMPANIES.MAIN },
  { email: TEST_USERS.VIEWER, role: 'viewer', company: TEST_COMPANIES.MAIN },
  { email: TEST_USERS.OTHER_ADMIN, role: 'admin', company: TEST_COMPANIES.OTHER }
]

export default async function globalSetup() {
  console.log('\n🔧 Setting up test environment...\n')
  
  try {
    // 1. Create test companies
    console.log('Creating test companies...')
    
    const { data: mainCompany } = await adminClient
      .from('companies')
      .upsert({ 
        name: 'Test Company', 
        slug: TEST_COMPANIES.MAIN,
        settings: { test: true }
      }, { onConflict: 'slug' })
      .select()
      .single()
    
    const { data: otherCompany } = await adminClient
      .from('companies')
      .upsert({ 
        name: 'Other Company', 
        slug: TEST_COMPANIES.OTHER,
        settings: { test: true }
      }, { onConflict: 'slug' })
      .select()
      .single()
    
    console.log(`  ✓ Created companies: ${mainCompany?.id}, ${otherCompany?.id}`)
    
    // 2. Create test users
    console.log('Creating test users...')
    
    for (const user of testUsers) {
      // Create auth user
      const { data: authUser, error: authError } = await adminClient.auth.admin.createUser({
        email: user.email,
        password: TEST_PASSWORD,
        email_confirm: true
      })
      
      if (authError && !authError.message.includes('already been registered')) {
        throw authError
      }
      
      const userId = authUser?.user?.id || (await getUserIdByEmail(user.email))
      
      // Get company ID
      const companyId = user.company === TEST_COMPANIES.MAIN ? mainCompany?.id : otherCompany?.id
      
      // Create company membership
      await adminClient
        .from('company_members')
        .upsert({
          company_id: companyId,
          user_id: userId,
          role: user.role,
          is_super_user: user.isSuperUser || false
        }, { onConflict: 'user_id' })
      
      console.log(`  ✓ Created user: ${user.email} (${user.role}${user.isSuperUser ? ', super' : ''})`)
    }
    
    // 3. Create test inventory items
    console.log('Creating test inventory items...')
    
    const testItems = [
      { name: 'Test Item 1', quantity: 100, sku: 'TEST-001', company_id: mainCompany?.id },
      { name: 'Test Item 2', quantity: 50, sku: 'TEST-002', company_id: mainCompany?.id },
      { name: 'Low Stock Item', quantity: 5, sku: 'TEST-003', low_stock_qty: 10, company_id: mainCompany?.id },
      { name: 'Out of Stock', quantity: 0, sku: 'TEST-004', company_id: mainCompany?.id },
      { name: 'Other Company Item', quantity: 200, sku: 'OTHER-001', company_id: otherCompany?.id }
    ]
    
    for (const item of testItems) {
      await adminClient
        .from('inventory_items')
        .upsert(item, { onConflict: 'company_id,sku' })
    }
    
    console.log(`  ✓ Created ${testItems.length} test items`)
    
    console.log('\n✅ Test environment ready!\n')
    
  } catch (error) {
    console.error('\n❌ Setup failed:', error)
    throw error
  }
}

async function getUserIdByEmail(email: string): Promise<string> {
  const { data } = await adminClient
    .from('profiles')
    .select('id')
    .eq('email', email)
    .single()
  return data?.id
}
```

### tests/setup/global-teardown.ts

```typescript
import { adminClient, TEST_COMPANIES } from './test-utils'

export default async function globalTeardown() {
  console.log('\n🧹 Cleaning up test environment...\n')
  
  try {
    // Get test company IDs
    const { data: companies } = await adminClient
      .from('companies')
      .select('id')
      .in('slug', [TEST_COMPANIES.MAIN, TEST_COMPANIES.OTHER])
    
    const companyIds = companies?.map(c => c.id) || []
    
    if (companyIds.length > 0) {
      // Delete in order (respecting foreign keys)
      // Order matters: child tables before parent tables
      
      // 1. Delete action_metrics
      await adminClient
        .from('action_metrics')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test action metrics')
      
      // 2. Delete inventory transactions
      await adminClient
        .from('inventory_transactions')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test inventory transactions')
      
      // 3. Delete inventory items
      await adminClient
        .from('inventory_items')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test inventory items')
      
      // 4. Delete inventory categories
      await adminClient
        .from('inventory_categories')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test inventory categories')
      
      // 5. Delete inventory locations
      await adminClient
        .from('inventory_locations')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test inventory locations')
      
      // 6. Delete inventory snapshots
      await adminClient
        .from('inventory_snapshots')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test snapshots')
      
      // 7. Delete order recipients
      await adminClient
        .from('order_recipients')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test order recipients')
      
      // 8. Delete orders
      await adminClient
        .from('orders')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test orders')
      
      // 9. Delete role change requests
      await adminClient
        .from('role_change_requests')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test role change requests')
      
      // 10. Delete audit logs
      await adminClient
        .from('audit_log')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test audit logs')
      
      // 11. Delete invitations
      await adminClient
        .from('invitations')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test invitations')
      
      // 12. Delete company members
      await adminClient
        .from('company_members')
        .delete()
        .in('company_id', companyIds)
      console.log('  ✓ Deleted test company members')
      
      // 13. Delete companies (last - parent of all)
      await adminClient
        .from('companies')
        .delete()
        .in('id', companyIds)
      console.log('  ✓ Deleted test companies')
    }
    
    // 14. Delete test auth users
    const testEmails = [
      'super@test.local',
      'admin@test.local',
      'member@test.local',
      'viewer@test.local',
      'other@test.local'
    ]
    
    for (const email of testEmails) {
      const { data: users } = await adminClient.auth.admin.listUsers()
      const user = users.users.find(u => u.email === email)
      if (user) {
        await adminClient.auth.admin.deleteUser(user.id)
      }
    }
    console.log('  ✓ Deleted test auth users')
    
    console.log('\n✅ Cleanup complete!\n')
    
  } catch (error) {
    console.error('\n⚠️ Teardown error (non-fatal):', error)
    // Don't throw - teardown errors shouldn't fail the test run
  }
}
```

---

## API/RPC Testing

### tests/integration/rls/inventory-items.test.ts

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('RLS: inventory_items', () => {
  let superClient: SupabaseClient
  let adminClientAuth: SupabaseClient
  let memberClient: SupabaseClient
  let viewerClient: SupabaseClient
  let otherAdminClient: SupabaseClient
  let mainCompanyId: string
  let otherCompanyId: string

  beforeAll(async () => {
    // Get authenticated clients
    superClient = await getClient('SUPER')
    adminClientAuth = await getClient('ADMIN')
    memberClient = await getClient('MEMBER')
    viewerClient = await getClient('VIEWER')
    otherAdminClient = await getClient('OTHER_ADMIN')
    
    // Get company IDs
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER)
  })

  describe('SELECT (Read)', () => {
    it('super user can see all companies items', async () => {
      const { data, error } = await superClient
        .from('inventory_items')
        .select('*, companies!inner(slug)')
      
      expect(error).toBeNull()
      expect(data).toBeDefined()
      
      // Should see items from both companies
      const slugs = [...new Set(data?.map(i => i.companies.slug))]
      expect(slugs).toContain(TEST_COMPANIES.MAIN)
      expect(slugs).toContain(TEST_COMPANIES.OTHER)
    })

    it('admin can only see own company items', async () => {
      const { data, error } = await adminClientAuth
        .from('inventory_items')
        .select('company_id')
      
      expect(error).toBeNull()
      expect(data).toBeDefined()
      expect(data!.length).toBeGreaterThan(0)
      
      // All items should be from main company
      const companyIds = [...new Set(data?.map(i => i.company_id))]
      expect(companyIds).toHaveLength(1)
      expect(companyIds[0]).toBe(mainCompanyId)
    })

    it('member can only see own company items', async () => {
      const { data, error } = await memberClient
        .from('inventory_items')
        .select('company_id')
      
      expect(error).toBeNull()
      expect(data!.every(i => i.company_id === mainCompanyId)).toBe(true)
    })

    it('viewer can only see own company items', async () => {
      const { data, error } = await viewerClient
        .from('inventory_items')
        .select('company_id')
      
      expect(error).toBeNull()
      expect(data!.every(i => i.company_id === mainCompanyId)).toBe(true)
    })

    it('other company admin cannot see main company items', async () => {
      const { data, error } = await otherAdminClient
        .from('inventory_items')
        .select('company_id')
        .eq('company_id', mainCompanyId)
      
      expect(error).toBeNull()
      expect(data).toHaveLength(0)  // Should be filtered out by RLS
    })

    it('deleted items are hidden by default', async () => {
      // First, soft delete an item using admin client
      const { data: items } = await adminClientAuth
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      // Soft delete via RPC
      await adminClientAuth.rpc('soft_delete_item', { p_item_id: items!.id })
      
      // Try to select it - should not appear
      const { data: visible } = await adminClientAuth
        .from('inventory_items')
        .select('id')
        .eq('id', items!.id)
      
      expect(visible).toHaveLength(0)  // Hidden by RLS deleted_at IS NULL
      
      // Restore it for other tests
      await adminClientAuth.rpc('restore_item', { p_item_id: items!.id })
    })
  })

  describe('INSERT (Create)', () => {
    it('admin can create items in own company', async () => {
      const { data, error } = await adminClientAuth
        .from('inventory_items')
        .insert({
          company_id: mainCompanyId,
          name: 'Admin Created Item',
          quantity: 10
        })
        .select()
        .single()
      
      expect(error).toBeNull()
      expect(data).toBeDefined()
      expect(data!.name).toBe('Admin Created Item')
      
      // Cleanup
      await adminClient.from('inventory_items').delete().eq('id', data!.id)
    })

    it('member can create items in own company', async () => {
      const { data, error } = await memberClient
        .from('inventory_items')
        .insert({
          company_id: mainCompanyId,
          name: 'Member Created Item',
          quantity: 5
        })
        .select()
        .single()
      
      expect(error).toBeNull()
      expect(data).toBeDefined()
      
      // Cleanup
      await adminClient.from('inventory_items').delete().eq('id', data!.id)
    })

    it('viewer cannot create items', async () => {
      const { error } = await viewerClient
        .from('inventory_items')
        .insert({
          company_id: mainCompanyId,
          name: 'Viewer Item',
          quantity: 1
        })
      
      expect(error).not.toBeNull()
      // RLS blocks insert
    })

    it('admin cannot create items in other company', async () => {
      const { error } = await adminClientAuth
        .from('inventory_items')
        .insert({
          company_id: otherCompanyId,  // Different company!
          name: 'Cross-tenant Item',
          quantity: 1
        })
      
      expect(error).not.toBeNull()
      // RLS blocks cross-tenant insert
    })
  })

  describe('UPDATE', () => {
    it('admin can update own company items', async () => {
      const { data: item } = await adminClientAuth
        .from('inventory_items')
        .select('id, quantity')
        .limit(1)
        .single()
      
      const newQty = item!.quantity + 1
      
      const { error } = await adminClientAuth
        .from('inventory_items')
        .update({ quantity: newQty })
        .eq('id', item!.id)
      
      expect(error).toBeNull()
      
      // Verify update
      const { data: updated } = await adminClientAuth
        .from('inventory_items')
        .select('quantity')
        .eq('id', item!.id)
        .single()
      
      expect(updated!.quantity).toBe(newQty)
    })

    it('member can update own company items', async () => {
      const { data: item } = await memberClient
        .from('inventory_items')
        .select('id, name')
        .limit(1)
        .single()
      
      const { error } = await memberClient
        .from('inventory_items')
        .update({ name: 'Updated by Member' })
        .eq('id', item!.id)
      
      expect(error).toBeNull()
      
      // Revert
      await adminClient
        .from('inventory_items')
        .update({ name: item!.name })
        .eq('id', item!.id)
    })

    it('viewer cannot update items', async () => {
      const { data: item } = await viewerClient
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      const { error } = await viewerClient
        .from('inventory_items')
        .update({ name: 'Viewer Update' })
        .eq('id', item!.id)
      
      expect(error).not.toBeNull()
    })

    it('admin cannot update other company items', async () => {
      // Get other company item ID via admin client
      const { data: otherItem } = await adminClient
        .from('inventory_items')
        .select('id')
        .eq('company_id', otherCompanyId)
        .limit(1)
        .single()
      
      // Try to update as main company admin
      const { data, error } = await adminClientAuth
        .from('inventory_items')
        .update({ name: 'Cross-tenant Update' })
        .eq('id', otherItem!.id)
        .select()
      
      // RLS should filter - no rows updated
      expect(data).toHaveLength(0)
    })
  })

  describe('DELETE (Blocked)', () => {
    it('hard DELETE is blocked for all users', async () => {
      const { data: item } = await adminClientAuth
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      // Direct delete should fail (no DELETE policy)
      const { error } = await adminClientAuth
        .from('inventory_items')
        .delete()
        .eq('id', item!.id)
      
      // Should error - no DELETE policy exists
      expect(error).not.toBeNull()
    })

    it('even super user cannot hard DELETE', async () => {
      const { data: item } = await superClient
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      const { error } = await superClient
        .from('inventory_items')
        .delete()
        .eq('id', item!.id)
      
      expect(error).not.toBeNull()
    })
  })
})
```

### tests/integration/rls/cross-tenant.test.ts

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('Cross-Tenant Isolation', () => {
  let adminClientAuth: SupabaseClient
  let otherAdminClient: SupabaseClient
  let mainCompanyId: string
  let otherCompanyId: string

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN')
    otherAdminClient = await getClient('OTHER_ADMIN')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER)
  })

  describe('Data Isolation', () => {
    it('cannot SELECT across tenant boundaries', async () => {
      // Main company admin tries to read other company's items
      const { data } = await adminClientAuth
        .from('inventory_items')
        .select('*')
      
      // Should only see own company's items
      const otherCompanyItems = data?.filter(i => i.company_id === otherCompanyId)
      expect(otherCompanyItems).toHaveLength(0)
    })

    it('cannot INSERT into other tenant', async () => {
      const { error } = await adminClientAuth
        .from('inventory_items')
        .insert({
          company_id: otherCompanyId,
          name: 'Malicious Insert',
          quantity: 999
        })
      
      expect(error).not.toBeNull()
    })

    it('cannot UPDATE other tenant data', async () => {
      // Get an item from other company
      const { data: otherItem } = await adminClient
        .from('inventory_items')
        .select('id, name')
        .eq('company_id', otherCompanyId)
        .limit(1)
        .single()
      
      const originalName = otherItem!.name
      
      // Try to update it
      await adminClientAuth
        .from('inventory_items')
        .update({ name: 'Hacked Name' })
        .eq('id', otherItem!.id)
      
      // Verify it wasn't changed
      const { data: stillSame } = await adminClient
        .from('inventory_items')
        .select('name')
        .eq('id', otherItem!.id)
        .single()
      
      expect(stillSame!.name).toBe(originalName)
    })

    it('audit log only shows own company entries', async () => {
      const { data } = await adminClientAuth
        .from('audit_log')
        .select('company_id')
      
      // All entries should be from own company (or null for global)
      const otherCompanyLogs = data?.filter(l => l.company_id === otherCompanyId)
      expect(otherCompanyLogs).toHaveLength(0)
    })

    it('snapshots only show own company', async () => {
      // Create snapshots for both companies
      await adminClient.rpc('create_snapshot', {
        p_company_id: mainCompanyId,
        p_name: 'Main Company Snapshot',
        p_type: 'manual'
      })
      
      await adminClient.rpc('create_snapshot', {
        p_company_id: otherCompanyId,
        p_name: 'Other Company Snapshot',
        p_type: 'manual'
      })
      
      // Main admin should only see main company snapshots
      const { data } = await adminClientAuth
        .from('inventory_snapshots')
        .select('company_id')
      
      expect(data?.every(s => s.company_id === mainCompanyId)).toBe(true)
    })
  })

  describe('RPC Cross-Tenant Protection', () => {
    it('soft_delete_item rejects other company items', async () => {
      const { data: otherItem } = await adminClient
        .from('inventory_items')
        .select('id')
        .eq('company_id', otherCompanyId)
        .limit(1)
        .single()
      
      const { data } = await adminClientAuth.rpc('soft_delete_item', {
        p_item_id: otherItem!.id
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('not found')  // RLS filters it out
    })

    it('soft_delete_order rejects other company orders', async () => {
      const { data: otherOrder } = await adminClient
        .from('orders')
        .select('id')
        .eq('company_id', otherCompanyId)
        .limit(1)
        .single()
      
      const { data } = await adminClientAuth.rpc('soft_delete_order', {
        p_order_id: otherOrder!.id
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('not found')
    })

    it('restore_order rejects other company orders', async () => {
      // Soft delete an order in other company first
      const { data: otherOrder } = await adminClient
        .from('orders')
        .select('id')
        .eq('company_id', otherCompanyId)
        .is('deleted_at', null)
        .limit(1)
        .single()
      
      // Use service role to soft delete it
      await adminClient
        .from('orders')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', otherOrder!.id)
      
      // Try to restore from main company admin
      const { data } = await adminClientAuth.rpc('restore_order', {
        p_order_id: otherOrder!.id
      })
      
      expect(data.success).toBe(false)
    })

    it('create_snapshot rejects other company', async () => {
      const { data } = await adminClientAuth.rpc('create_snapshot', {
        p_company_id: otherCompanyId,
        p_name: 'Cross-tenant Snapshot',
        p_type: 'manual'
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })

    it('invite_user rejects other company', async () => {
      const { data } = await adminClientAuth.rpc('invite_user', {
        p_company_id: otherCompanyId,
        p_email: 'hacker@evil.com',
        p_role: 'admin'
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })

    it('get_audit_log rejects other company', async () => {
      const { data } = await adminClientAuth.rpc('get_audit_log', {
        p_company_id: otherCompanyId
      })
      
      // Should return empty (not error) because RLS filters
      expect(data).toHaveLength(0)
    })

    it('get_deleted_items rejects other company', async () => {
      const { data } = await adminClientAuth.rpc('get_deleted_items', {
        p_company_id: otherCompanyId
      })
      
      expect(data).toHaveLength(0)
    })
  })
})
```

### tests/integration/security/privilege-escalation.test.ts

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { getClient, getCompanyId, getUserId, TEST_COMPANIES, TEST_USERS, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('Privilege Escalation Prevention', () => {
  let adminClientAuth: SupabaseClient
  let memberClient: SupabaseClient
  let viewerClient: SupabaseClient
  let mainCompanyId: string
  let memberId: string
  let viewerId: string

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN')
    memberClient = await getClient('MEMBER')
    viewerClient = await getClient('VIEWER')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    memberId = await getUserId(TEST_USERS.MEMBER)
    viewerId = await getUserId(TEST_USERS.VIEWER)
  })

  describe('is_super_user Protection', () => {
    it('admin cannot set is_super_user=true via INSERT', async () => {
      // Create a temporary auth user just for this test
      const tempEmail = `temp-${Date.now()}@test.local`
      const { data: authData } = await adminClient.auth.admin.createUser({
        email: tempEmail,
        password: 'TempPass123!',
        email_confirm: true
      })
      const tempUserId = authData.user!.id
      
      try {
        // Admin tries to add user to company with is_super_user=true
        const { error } = await adminClientAuth
          .from('company_members')
          .insert({
            company_id: mainCompanyId,
            user_id: tempUserId,
            role: 'admin',
            is_super_user: true  // RLS should block this
          })
        
        expect(error).not.toBeNull()
        // RLS WITH CHECK blocks is_super_user=true
      } finally {
        // Always cleanup: delete membership if created, then delete auth user
        await adminClient
          .from('company_members')
          .delete()
          .eq('user_id', tempUserId)
        await adminClient.auth.admin.deleteUser(tempUserId)
      }
    })

    it('admin cannot set is_super_user=true via UPDATE', async () => {
      // Get own membership
      const { data: membership } = await adminClientAuth
        .from('company_members')
        .select('id')
        .eq('user_id', memberId)
        .single()
      
      const { error } = await adminClientAuth
        .from('company_members')
        .update({ is_super_user: true })
        .eq('id', membership!.id)
      
      expect(error).not.toBeNull()
      // RLS WITH CHECK blocks is_super_user=true
    })

    it('non-super user cannot call set_super_user RPC', async () => {
      const { data } = await adminClientAuth.rpc('set_super_user', {
        p_user_id: memberId,
        p_is_super: true
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Only super users')
    })
  })

  describe('Role Escalation', () => {
    it('member cannot change own role via UPDATE', async () => {
      const { data: membership } = await memberClient
        .from('company_members')
        .select('id, role')
        .single()
      
      const { error } = await memberClient
        .from('company_members')
        .update({ role: 'admin' })
        .eq('id', membership!.id)
      
      // Should fail - member can't invoke UPDATE policy
      expect(error).not.toBeNull()
    })

    it('viewer cannot change own role', async () => {
      const { data: membership } = await viewerClient
        .from('company_members')
        .select('id')
        .single()
      
      const { error } = await viewerClient
        .from('company_members')
        .update({ role: 'admin' })
        .eq('id', membership!.id)
      
      expect(error).not.toBeNull()
    })
  })

  describe('Delete Permission', () => {
    it('member cannot soft delete items', async () => {
      const { data: item } = await memberClient
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      const { data } = await memberClient.rpc('soft_delete_item', {
        p_item_id: item!.id
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })

    it('viewer cannot soft delete items', async () => {
      const { data: item } = await viewerClient
        .from('inventory_items')
        .select('id')
        .limit(1)
        .single()
      
      const { data } = await viewerClient.rpc('soft_delete_item', {
        p_item_id: item!.id
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })
  })

  describe('Invitation Permission', () => {
    it('member cannot invite users', async () => {
      const { data } = await memberClient.rpc('invite_user', {
        p_company_id: mainCompanyId,
        p_email: 'newuser@test.local',
        p_role: 'viewer'
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })

    it('viewer cannot invite users', async () => {
      const { data } = await viewerClient.rpc('invite_user', {
        p_company_id: mainCompanyId,
        p_email: 'newuser@test.local',
        p_role: 'viewer'
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })
  })

  describe('Super User Only Functions', () => {
    it('admin cannot restore snapshots', async () => {
      // Create a snapshot first
      const { data: snapshot } = await adminClientAuth.rpc('create_snapshot', {
        p_company_id: mainCompanyId,
        p_name: 'Test Snapshot',
        p_type: 'manual'
      })
      
      // Try to restore it (should fail - not super user)
      const { data } = await adminClientAuth.rpc('restore_snapshot', {
        p_snapshot_id: snapshot.snapshot_id
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Only super users')
    })

    it('admin cannot undo actions', async () => {
      // Get an audit log entry
      const { data: audit } = await adminClient
        .from('audit_log')
        .select('id')
        .eq('company_id', mainCompanyId)
        .limit(1)
        .single()
      
      if (audit) {
        const { data } = await adminClientAuth.rpc('undo_action', {
          p_audit_id: audit.id
        })
        
        expect(data.success).toBe(false)
        expect(data.error).toContain('Only super users')
      }
    })

    it('admin cannot view platform metrics', async () => {
      const { data } = await adminClientAuth.rpc('get_platform_metrics')
      
      expect(data.error).toBe('Unauthorized')
    })

    it('admin cannot view all companies', async () => {
      const { data } = await adminClientAuth.rpc('get_all_companies')
      
      // Returns empty (not an error), but should have 0 rows
      expect(data).toHaveLength(0)
    })

    it('admin cannot view all users', async () => {
      const { data } = await adminClientAuth.rpc('get_all_users')
      
      expect(data).toHaveLength(0)
    })
  })
})
```

### tests/integration/rpc/soft-delete.test.ts

```typescript
import { describe, it, expect, beforeAll, afterEach } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('RPC: Soft Delete Functions', () => {
  let superClient: SupabaseClient
  let adminClientAuth: SupabaseClient
  let mainCompanyId: string
  let otherCompanyId: string
  let testItemId: string

  beforeAll(async () => {
    superClient = await getClient('SUPER')
    adminClientAuth = await getClient('ADMIN')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER)
  })

  // Create fresh test item before tests that need it
  async function createTestItem(): Promise<string> {
    const { data } = await adminClient
      .from('inventory_items')
      .insert({
        company_id: mainCompanyId,
        name: `Delete Test ${Date.now()}`,
        quantity: 10
      })
      .select('id')
      .single()
    return data!.id
  }

  afterEach(async () => {
    // Cleanup any test items
    if (testItemId) {
      await adminClient
        .from('inventory_items')
        .delete()
        .eq('id', testItemId)
      testItemId = ''
    }
  })

  describe('soft_delete_item', () => {
    it('admin can soft delete own company item', async () => {
      testItemId = await createTestItem()
      
      const { data } = await adminClientAuth.rpc('soft_delete_item', {
        p_item_id: testItemId
      })
      
      expect(data.success).toBe(true)
      expect(data.message).toContain('trash')
      
      // Verify it's soft deleted (deleted_at is set)
      const { data: item } = await adminClient
        .from('inventory_items')
        .select('deleted_at, deleted_by')
        .eq('id', testItemId)
        .single()
      
      expect(item!.deleted_at).not.toBeNull()
      expect(item!.deleted_by).not.toBeNull()
    })

    it('cannot delete item that does not exist', async () => {
      const { data } = await adminClientAuth.rpc('soft_delete_item', {
        p_item_id: '00000000-0000-0000-0000-000000000000'
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('not found')
    })

    it('cannot delete already deleted item', async () => {
      testItemId = await createTestItem()
      
      // Delete once
      await adminClientAuth.rpc('soft_delete_item', { p_item_id: testItemId })
      
      // Try to delete again
      const { data } = await adminClientAuth.rpc('soft_delete_item', {
        p_item_id: testItemId
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('not found')  // Already deleted
    })
  })

  describe('soft_delete_items (bulk)', () => {
    it('can bulk delete multiple items', async () => {
      // Create multiple items
      const id1 = await createTestItem()
      const id2 = await createTestItem()
      
      const { data } = await adminClientAuth.rpc('soft_delete_items', {
        p_item_ids: [id1, id2]
      })
      
      expect(data.success).toBe(true)
      expect(data.deleted_count).toBe(2)
      
      // Cleanup
      await adminClient.from('inventory_items').delete().in('id', [id1, id2])
    })

    it('creates snapshot before bulk delete', async () => {
      const id1 = await createTestItem()
      const id2 = await createTestItem()
      
      // Count snapshots before
      const { count: beforeCount } = await adminClient
        .from('inventory_snapshots')
        .select('*', { count: 'exact', head: true })
        .eq('company_id', mainCompanyId)
      
      // Bulk delete
      await adminClientAuth.rpc('soft_delete_items', {
        p_item_ids: [id1, id2]
      })
      
      // Count snapshots after
      const { count: afterCount } = await adminClient
        .from('inventory_snapshots')
        .select('*', { count: 'exact', head: true })
        .eq('company_id', mainCompanyId)
      
      expect(afterCount).toBe((beforeCount || 0) + 1)
      
      // Verify snapshot type
      const { data: snapshot } = await adminClient
        .from('inventory_snapshots')
        .select('snapshot_type')
        .eq('company_id', mainCompanyId)
        .order('created_at', { ascending: false })
        .limit(1)
        .single()
      
      expect(snapshot!.snapshot_type).toBe('pre_bulk_delete')
      
      // Cleanup
      await adminClient.from('inventory_items').delete().in('id', [id1, id2])
    })

    it('REJECTS mixed-company item list (CRITICAL SECURITY)', async () => {
      // Create item in main company
      const mainItemId = await createTestItem()
      
      // Get item from other company
      const { data: otherItem } = await adminClient
        .from('inventory_items')
        .select('id')
        .eq('company_id', otherCompanyId)
        .limit(1)
        .single()
      
      // Try to delete both (should fail!)
      const { data } = await adminClientAuth.rpc('soft_delete_items', {
        p_item_ids: [mainItemId, otherItem!.id]
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Invalid item selection')
      
      // Verify neither was deleted
      const { data: mainItem } = await adminClient
        .from('inventory_items')
        .select('deleted_at')
        .eq('id', mainItemId)
        .single()
      
      expect(mainItem!.deleted_at).toBeNull()
      
      // Cleanup
      await adminClient.from('inventory_items').delete().eq('id', mainItemId)
    })

    it('rejects empty item list', async () => {
      const { data } = await adminClientAuth.rpc('soft_delete_items', {
        p_item_ids: []
      })
      
      expect(data.success).toBe(false)
    })
  })

  describe('restore_item', () => {
    it('admin can restore deleted item', async () => {
      testItemId = await createTestItem()
      
      // Delete it
      await adminClientAuth.rpc('soft_delete_item', { p_item_id: testItemId })
      
      // Restore it
      const { data } = await adminClientAuth.rpc('restore_item', {
        p_item_id: testItemId
      })
      
      expect(data.success).toBe(true)
      
      // Verify restored
      const { data: item } = await adminClient
        .from('inventory_items')
        .select('deleted_at')
        .eq('id', testItemId)
        .single()
      
      expect(item!.deleted_at).toBeNull()
    })

    it('cannot restore item that is not deleted', async () => {
      testItemId = await createTestItem()
      
      const { data } = await adminClientAuth.rpc('restore_item', {
        p_item_id: testItemId
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('not found')
    })

    it('creates audit log entry on restore', async () => {
      testItemId = await createTestItem()
      
      await adminClientAuth.rpc('soft_delete_item', { p_item_id: testItemId })
      await adminClientAuth.rpc('restore_item', { p_item_id: testItemId })
      
      // Check audit log
      const { data: audit } = await adminClient
        .from('audit_log')
        .select('action')
        .eq('record_id', testItemId)
        .eq('action', 'RESTORE')
        .single()
      
      expect(audit).toBeDefined()
      expect(audit!.action).toBe('RESTORE')
    })
  })
})
```

### tests/integration/security/company-id-immutable.test.ts

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('company_id Immutability (Trigger Protection)', () => {
  let adminClientAuth: SupabaseClient
  let mainCompanyId: string
  let otherCompanyId: string

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER)
  })

  const tablesToTest = [
    { table: 'inventory_items', createFn: async () => {
      const { data } = await adminClient.from('inventory_items')
        .insert({ company_id: mainCompanyId, name: 'Test', quantity: 1 })
        .select('id').single()
      return data!.id
    }},
    { table: 'inventory_locations', createFn: async () => {
      const { data } = await adminClient.from('inventory_locations')
        .insert({ company_id: mainCompanyId, name: 'Test Location' })
        .select('id').single()
      return data!.id
    }},
    { table: 'inventory_categories', createFn: async () => {
      const { data } = await adminClient.from('inventory_categories')
        .insert({ company_id: mainCompanyId, name: 'Test Category' })
        .select('id').single()
      return data!.id
    }},
    { table: 'orders', createFn: async () => {
      const { data } = await adminClient.from('orders')
        .insert({ company_id: mainCompanyId })
        .select('id').single()
      return data!.id
    }},
  ]

  for (const { table, createFn } of tablesToTest) {
    it(`cannot change company_id on ${table}`, async () => {
      const recordId = await createFn()
      
      // Try to change company_id (should be blocked by trigger)
      const { error } = await adminClient
        .from(table)
        .update({ company_id: otherCompanyId })
        .eq('id', recordId)
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('Cannot change company_id')
      
      // Cleanup
      await adminClient.from(table).delete().eq('id', recordId)
    })
  }

  it('cannot change company_id on company_members', async () => {
    // Get a member record
    const { data: member } = await adminClient
      .from('company_members')
      .select('id')
      .eq('company_id', mainCompanyId)
      .limit(1)
      .single()
    
    const { error } = await adminClient
      .from('company_members')
      .update({ company_id: otherCompanyId })
      .eq('id', member!.id)
    
    expect(error).not.toBeNull()
    expect(error!.message).toContain('Cannot change company_id')
  })
})
```

### tests/integration/security/cross-tenant-fk.test.ts

```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('Cross-Tenant FK Validation (Trigger Protection)', () => {
  let adminClientAuth: SupabaseClient
  let mainCompanyId: string
  let otherCompanyId: string
  let otherCategoryId: string
  let otherLocationId: string
  let otherItemId: string

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
    otherCompanyId = await getCompanyId(TEST_COMPANIES.OTHER)
    
    // Create test records in OTHER company
    const { data: cat } = await adminClient.from('inventory_categories')
      .insert({ company_id: otherCompanyId, name: 'Other Category' })
      .select('id').single()
    otherCategoryId = cat!.id
    
    const { data: loc } = await adminClient.from('inventory_locations')
      .insert({ company_id: otherCompanyId, name: 'Other Location' })
      .select('id').single()
    otherLocationId = loc!.id
    
    const { data: item } = await adminClient.from('inventory_items')
      .insert({ company_id: otherCompanyId, name: 'Other Item', quantity: 1 })
      .select('id').single()
    otherItemId = item!.id
  })

  afterAll(async () => {
    // Cleanup
    await adminClient.from('inventory_items').delete().eq('id', otherItemId)
    await adminClient.from('inventory_categories').delete().eq('id', otherCategoryId)
    await adminClient.from('inventory_locations').delete().eq('id', otherLocationId)
  })

  describe('inventory_items FK validation', () => {
    it('rejects INSERT with category_id from different company', async () => {
      const { error } = await adminClient.from('inventory_items').insert({
        company_id: mainCompanyId,
        name: 'Cross-tenant category test',
        quantity: 1,
        category_id: otherCategoryId  // From OTHER company!
      })
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('category_id must belong to same company')
    })

    it('rejects INSERT with location_id from different company', async () => {
      const { error } = await adminClient.from('inventory_items').insert({
        company_id: mainCompanyId,
        name: 'Cross-tenant location test',
        quantity: 1,
        location_id: otherLocationId  // From OTHER company!
      })
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('location_id must belong to same company')
    })

    it('rejects UPDATE with category_id from different company', async () => {
      // Create a valid item first
      const { data: item } = await adminClient.from('inventory_items')
        .insert({ company_id: mainCompanyId, name: 'Test', quantity: 1 })
        .select('id').single()
      
      const { error } = await adminClient.from('inventory_items')
        .update({ category_id: otherCategoryId })
        .eq('id', item!.id)
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('category_id must belong to same company')
      
      // Cleanup
      await adminClient.from('inventory_items').delete().eq('id', item!.id)
    })
  })

  describe('inventory_categories parent_category_id validation', () => {
    it('rejects INSERT with parent_category_id from different company', async () => {
      const { error } = await adminClient.from('inventory_categories').insert({
        company_id: mainCompanyId,
        name: 'Cross-tenant parent test',
        parent_category_id: otherCategoryId  // From OTHER company!
      })
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('parent_category_id must belong to same company')
    })

    it('rejects UPDATE with parent_category_id from different company', async () => {
      // Create a valid category first
      const { data: cat } = await adminClient.from('inventory_categories')
        .insert({ company_id: mainCompanyId, name: 'Test Category' })
        .select('id').single()
      
      const { error } = await adminClient.from('inventory_categories')
        .update({ parent_category_id: otherCategoryId })
        .eq('id', cat!.id)
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('parent_category_id must belong to same company')
      
      // Cleanup
      await adminClient.from('inventory_categories').delete().eq('id', cat!.id)
    })
  })

  describe('inventory_transactions FK validation', () => {
    it('rejects INSERT with item_id from different company', async () => {
      const { error } = await adminClient.from('inventory_transactions').insert({
        company_id: mainCompanyId,
        item_id: otherItemId,  // From OTHER company!
        transaction_type: 'adjusted',
        quantity_change: 1
      })
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('item_id must belong to same company')
    })

    it('rejects INSERT with from_location_id from different company', async () => {
      // Get a valid item from main company
      const { data: mainItem } = await adminClient.from('inventory_items')
        .select('id').eq('company_id', mainCompanyId).limit(1).single()
      
      const { error } = await adminClient.from('inventory_transactions').insert({
        company_id: mainCompanyId,
        item_id: mainItem!.id,
        transaction_type: 'transferred',
        quantity_change: -1,
        from_location_id: otherLocationId  // From OTHER company!
      })
      
      expect(error).not.toBeNull()
      expect(error!.message).toContain('from_location_id must belong to same company')
    })
  })
})
```

### tests/integration/security/deleted-at-rls.test.ts

```typescript
import { describe, it, expect, beforeAll, afterEach } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('deleted_at RLS Protection (RPC-Only)', () => {
  let superClient: SupabaseClient
  let adminClientAuth: SupabaseClient
  let memberClient: SupabaseClient
  let mainCompanyId: string
  let testItemId: string

  beforeAll(async () => {
    superClient = await getClient('SUPER')
    adminClientAuth = await getClient('ADMIN')
    memberClient = await getClient('MEMBER')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
  })

  async function createTestItem(): Promise<string> {
    const { data } = await adminClient.from('inventory_items')
      .insert({ company_id: mainCompanyId, name: `Test ${Date.now()}`, quantity: 10 })
      .select('id').single()
    return data!.id
  }

  afterEach(async () => {
    if (testItemId) {
      await adminClient.from('inventory_items').delete().eq('id', testItemId)
      testItemId = ''
    }
  })

  describe('Direct deleted_at UPDATE blocked by RLS', () => {
    it('member cannot set deleted_at directly', async () => {
      testItemId = await createTestItem()
      
      const { error } = await memberClient
        .from('inventory_items')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', testItemId)
      
      // RLS WITH CHECK blocks this
      expect(error).not.toBeNull()
    })

    it('admin cannot set deleted_at directly', async () => {
      testItemId = await createTestItem()
      
      const { data, error } = await adminClientAuth
        .from('inventory_items')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', testItemId)
        .select()
      
      // RLS WITH CHECK blocks this - either error or no rows updated
      if (!error) {
        expect(data).toHaveLength(0)
      }
    })

    it('super user cannot set deleted_at directly via UPDATE', async () => {
      testItemId = await createTestItem()
      
      const { data, error } = await superClient
        .from('inventory_items')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', testItemId)
        .select()
      
      // RLS WITH CHECK blocks even super user's direct UPDATE
      if (!error) {
        expect(data).toHaveLength(0)
      }
    })

    it('soft_delete_item RPC DOES set deleted_at (bypasses RLS)', async () => {
      testItemId = await createTestItem()
      
      const { data } = await adminClientAuth.rpc('soft_delete_item', {
        p_item_id: testItemId
      })
      
      expect(data.success).toBe(true)
      
      // Verify it was actually deleted
      const { data: item } = await adminClient
        .from('inventory_items')
        .select('deleted_at')
        .eq('id', testItemId)
        .single()
      
      expect(item!.deleted_at).not.toBeNull()
    })
  })

  describe('Trashed items are read-only', () => {
    it('cannot UPDATE a trashed item', async () => {
      testItemId = await createTestItem()
      
      // Soft delete via RPC
      await adminClientAuth.rpc('soft_delete_item', { p_item_id: testItemId })
      
      // Try to update it
      const { data, error } = await adminClientAuth
        .from('inventory_items')
        .update({ name: 'New Name' })
        .eq('id', testItemId)
        .select()
      
      // RLS USING blocks this (deleted_at IS NULL required)
      if (!error) {
        expect(data).toHaveLength(0)
      }
    })
  })

  describe('INSERT deleted_at guard', () => {
    it('cannot INSERT with deleted_at already set', async () => {
      const { error } = await adminClientAuth
        .from('inventory_items')
        .insert({
          company_id: mainCompanyId,
          name: 'Pre-deleted item',
          quantity: 1,
          deleted_at: new Date().toISOString()  // Already deleted!
        })
      
      // RLS WITH CHECK blocks this
      expect(error).not.toBeNull()
    })

    it('cannot INSERT location with deleted_at set', async () => {
      const { error } = await adminClientAuth
        .from('inventory_locations')
        .insert({
          company_id: mainCompanyId,
          name: 'Pre-deleted location',
          deleted_at: new Date().toISOString()
        })
      
      expect(error).not.toBeNull()
    })

    it('cannot INSERT category with deleted_at set', async () => {
      const { error } = await adminClientAuth
        .from('inventory_categories')
        .insert({
          company_id: mainCompanyId,
          name: 'Pre-deleted category',
          deleted_at: new Date().toISOString()
        })
      
      expect(error).not.toBeNull()
    })

    it('cannot INSERT order with deleted_at set', async () => {
      const { error } = await adminClientAuth
        .from('orders')
        .insert({
          company_id: mainCompanyId,
          deleted_at: new Date().toISOString()
        })
      
      expect(error).not.toBeNull()
    })
  })
})
```

### tests/integration/rpc/order-soft-delete.test.ts

```typescript
import { describe, it, expect, beforeAll, afterEach } from 'vitest'
import { getClient, getCompanyId, TEST_COMPANIES, adminClient } from '../../setup/test-utils'
import { SupabaseClient } from '@supabase/supabase-js'

describe('RPC: Order Soft Delete Functions', () => {
  let adminClientAuth: SupabaseClient
  let memberClient: SupabaseClient
  let mainCompanyId: string
  let testOrderId: string

  beforeAll(async () => {
    adminClientAuth = await getClient('ADMIN')
    memberClient = await getClient('MEMBER')
    mainCompanyId = await getCompanyId(TEST_COMPANIES.MAIN)
  })

  async function createTestOrder(): Promise<string> {
    const { data } = await adminClient.from('orders')
      .insert({ company_id: mainCompanyId })
      .select('id').single()
    return data!.id
  }

  afterEach(async () => {
    if (testOrderId) {
      await adminClient.from('orders').delete().eq('id', testOrderId)
      testOrderId = ''
    }
  })

  describe('soft_delete_order', () => {
    it('admin can soft delete order', async () => {
      testOrderId = await createTestOrder()
      
      const { data } = await adminClientAuth.rpc('soft_delete_order', {
        p_order_id: testOrderId
      })
      
      expect(data.success).toBe(true)
      
      // Verify deleted
      const { data: order } = await adminClient
        .from('orders')
        .select('deleted_at, deleted_by')
        .eq('id', testOrderId)
        .single()
      
      expect(order!.deleted_at).not.toBeNull()
      expect(order!.deleted_by).not.toBeNull()
    })

    it('member cannot soft delete order (permission denied)', async () => {
      testOrderId = await createTestOrder()
      
      const { data } = await memberClient.rpc('soft_delete_order', {
        p_order_id: testOrderId
      })
      
      expect(data.success).toBe(false)
      expect(data.error).toContain('Permission denied')
    })

    it('logs to action_metrics as delete', async () => {
      testOrderId = await createTestOrder()
      
      await adminClientAuth.rpc('soft_delete_order', { p_order_id: testOrderId })
      
      // Check metrics
      const { data: metrics } = await adminClient
        .from('action_metrics')
        .select('action_type')
        .eq('table_name', 'orders')
        .eq('action_type', 'delete')
        .limit(1)
        .single()
      
      expect(metrics).toBeDefined()
      expect(metrics!.action_type).toBe('delete')
    })
  })

  describe('restore_order', () => {
    it('admin can restore deleted order', async () => {
      testOrderId = await createTestOrder()
      
      // Delete it
      await adminClientAuth.rpc('soft_delete_order', { p_order_id: testOrderId })
      
      // Restore it
      const { data } = await adminClientAuth.rpc('restore_order', {
        p_order_id: testOrderId
      })
      
      expect(data.success).toBe(true)
      
      // Verify restored
      const { data: order } = await adminClient
        .from('orders')
        .select('deleted_at')
        .eq('id', testOrderId)
        .single()
      
      expect(order!.deleted_at).toBeNull()
    })

    it('logs to action_metrics as restore', async () => {
      testOrderId = await createTestOrder()
      
      await adminClientAuth.rpc('soft_delete_order', { p_order_id: testOrderId })
      await adminClientAuth.rpc('restore_order', { p_order_id: testOrderId })
      
      // Check metrics
      const { data: metrics } = await adminClient
        .from('action_metrics')
        .select('action_type')
        .eq('table_name', 'orders')
        .eq('action_type', 'restore')
        .limit(1)
        .single()
      
      expect(metrics).toBeDefined()
      expect(metrics!.action_type).toBe('restore')
    })
  })
})
```

---

## Frontend Unit Testing

### tests/unit/utils.test.ts

```typescript
import { describe, it, expect } from 'vitest'

// Import or define the functions to test
// These would be extracted from your main app.js into utils.js

function formatNumber(num: number | null | undefined): string {
  if (num === null || num === undefined) return '0'
  return new Intl.NumberFormat('en-US', { 
    minimumFractionDigits: 0, 
    maximumFractionDigits: 2 
  }).format(num)
}

function formatStatus(status: string): string {
  const labels: Record<string, string> = {
    'out_of_stock': '🔴 OUT OF STOCK',
    'critical': '🔴 CRITICAL',
    'low': '🟡 LOW',
    'ok': '✅ OK'
  }
  return labels[status] || status
}

function parseCSVLine(line: string): string[] {
  const result: string[] = []
  let current = ''
  let inQuotes = false
  
  for (const char of line) {
    if (char === '"') {
      inQuotes = !inQuotes
    } else if (char === ',' && !inQuotes) {
      result.push(current)
      current = ''
    } else {
      current += char
    }
  }
  result.push(current)
  return result
}

describe('formatNumber', () => {
  it('formats integers with commas', () => {
    expect(formatNumber(1000)).toBe('1,000')
    expect(formatNumber(1234567)).toBe('1,234,567')
  })

  it('formats decimals correctly', () => {
    expect(formatNumber(1234.56)).toBe('1,234.56')
    expect(formatNumber(1234.5)).toBe('1,234.5')
  })

  it('handles small numbers', () => {
    expect(formatNumber(0)).toBe('0')
    expect(formatNumber(1)).toBe('1')
    expect(formatNumber(99)).toBe('99')
  })

  it('handles null and undefined', () => {
    expect(formatNumber(null)).toBe('0')
    expect(formatNumber(undefined)).toBe('0')
  })

  it('handles negative numbers', () => {
    expect(formatNumber(-1000)).toBe('-1,000')
  })
})

describe('formatStatus', () => {
  it('formats out_of_stock', () => {
    expect(formatStatus('out_of_stock')).toBe('🔴 OUT OF STOCK')
  })

  it('formats critical', () => {
    expect(formatStatus('critical')).toBe('🔴 CRITICAL')
  })

  it('formats low', () => {
    expect(formatStatus('low')).toBe('🟡 LOW')
  })

  it('formats ok', () => {
    expect(formatStatus('ok')).toBe('✅ OK')
  })

  it('returns unknown status unchanged', () => {
    expect(formatStatus('unknown')).toBe('unknown')
  })
})

describe('parseCSVLine', () => {
  it('parses simple CSV', () => {
    expect(parseCSVLine('a,b,c')).toEqual(['a', 'b', 'c'])
  })

  it('handles quoted fields', () => {
    expect(parseCSVLine('"hello","world"')).toEqual(['hello', 'world'])
  })

  it('handles commas in quoted fields', () => {
    expect(parseCSVLine('"a,b",c,d')).toEqual(['a,b', 'c', 'd'])
  })

  it('handles empty fields', () => {
    expect(parseCSVLine('a,,c')).toEqual(['a', '', 'c'])
  })

  it('handles single field', () => {
    expect(parseCSVLine('hello')).toEqual(['hello'])
  })

  it('handles empty string', () => {
    expect(parseCSVLine('')).toEqual([''])
  })

  it('handles complex CSV row', () => {
    expect(parseCSVLine('"Widget, Large",100,12.50,"Warehouse A"'))
      .toEqual(['Widget, Large', '100', '12.50', 'Warehouse A'])
  })
})
```

### tests/unit/permissions.test.ts

```typescript
import { describe, it, expect, beforeEach } from 'vitest'

// Mock SB object
const SB = {
  permissions: {
    role: null as string | null,
    is_super_user: false,
    can_read: false,
    can_create: false,
    can_update: false,
    can_delete: false,
    can_invite: false,
    can_manage_users: false,
    can_view_all_companies: false
  }
}

// Permission helpers
function canDelete(): boolean {
  return SB.permissions.can_delete === true
}

function canCreate(): boolean {
  return SB.permissions.can_create === true
}

function canUpdate(): boolean {
  return SB.permissions.can_update === true
}

function canInvite(): boolean {
  return SB.permissions.can_invite === true
}

function isSuperUser(): boolean {
  return SB.permissions.is_super_user === true
}

describe('Permission Helpers', () => {
  beforeEach(() => {
    // Reset permissions
    SB.permissions = {
      role: null,
      is_super_user: false,
      can_read: false,
      can_create: false,
      can_update: false,
      can_delete: false,
      can_invite: false,
      can_manage_users: false,
      can_view_all_companies: false
    }
  })

  describe('Super User', () => {
    beforeEach(() => {
      SB.permissions = {
        role: 'super_user',
        is_super_user: true,
        can_read: true,
        can_create: true,
        can_update: true,
        can_delete: true,
        can_invite: true,
        can_manage_users: true,
        can_view_all_companies: true
      }
    })

    it('isSuperUser returns true', () => {
      expect(isSuperUser()).toBe(true)
    })

    it('has all permissions', () => {
      expect(canDelete()).toBe(true)
      expect(canCreate()).toBe(true)
      expect(canUpdate()).toBe(true)
      expect(canInvite()).toBe(true)
    })
  })

  describe('Admin', () => {
    beforeEach(() => {
      SB.permissions = {
        role: 'admin',
        is_super_user: false,
        can_read: true,
        can_create: true,
        can_update: true,
        can_delete: true,
        can_invite: true,
        can_manage_users: true,
        can_view_all_companies: false
      }
    })

    it('isSuperUser returns false', () => {
      expect(isSuperUser()).toBe(false)
    })

    it('can delete', () => {
      expect(canDelete()).toBe(true)
    })

    it('can invite', () => {
      expect(canInvite()).toBe(true)
    })
  })

  describe('Member', () => {
    beforeEach(() => {
      SB.permissions = {
        role: 'member',
        is_super_user: false,
        can_read: true,
        can_create: true,
        can_update: true,
        can_delete: false,
        can_invite: false,
        can_manage_users: false,
        can_view_all_companies: false
      }
    })

    it('cannot delete', () => {
      expect(canDelete()).toBe(false)
    })

    it('can create', () => {
      expect(canCreate()).toBe(true)
    })

    it('can update', () => {
      expect(canUpdate()).toBe(true)
    })

    it('cannot invite', () => {
      expect(canInvite()).toBe(false)
    })
  })

  describe('Viewer', () => {
    beforeEach(() => {
      SB.permissions = {
        role: 'viewer',
        is_super_user: false,
        can_read: true,
        can_create: false,
        can_update: false,
        can_delete: false,
        can_invite: false,
        can_manage_users: false,
        can_view_all_companies: false
      }
    })

    it('cannot delete', () => {
      expect(canDelete()).toBe(false)
    })

    it('cannot create', () => {
      expect(canCreate()).toBe(false)
    })

    it('cannot update', () => {
      expect(canUpdate()).toBe(false)
    })

    it('cannot invite', () => {
      expect(canInvite()).toBe(false)
    })
  })

  describe('No Permissions (Not Logged In)', () => {
    it('all permissions false by default', () => {
      expect(canDelete()).toBe(false)
      expect(canCreate()).toBe(false)
      expect(canUpdate()).toBe(false)
      expect(canInvite()).toBe(false)
      expect(isSuperUser()).toBe(false)
    })
  })
})
```

---

## End-to-End Testing

### tests/e2e/auth.spec.ts

```typescript
import { test, expect } from '@playwright/test'

test.describe('Authentication', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
  })

  test('shows login form, no signup option', async ({ page }) => {
    // Should see login modal or form
    await expect(page.locator('text=Sign In')).toBeVisible()
    
    // Should NOT see signup options
    await expect(page.locator('text=Sign Up')).not.toBeVisible()
    await expect(page.locator('text=Create Account')).not.toBeVisible()
    await expect(page.locator('text=Register')).not.toBeVisible()
    
    // Should see invitation note
    await expect(page.locator('text=invitation')).toBeVisible()
  })

  test('successful login redirects to inventory', async ({ page }) => {
    await page.fill('input[type="email"]', 'admin@test.local')
    await page.fill('input[type="password"]', process.env.TEST_USER_PASSWORD!)
    await page.click('button:has-text("Sign In")')
    
    // Should see inventory content
    await expect(page.locator('table, [data-testid="inventory"]')).toBeVisible({ timeout: 10000 })
  })

  test('invalid credentials show error', async ({ page }) => {
    await page.fill('input[type="email"]', 'wrong@email.com')
    await page.fill('input[type="password"]', 'wrongpassword')
    await page.click('button:has-text("Sign In")')
    
    // Should see error message
    await expect(page.locator('.error, .toast-error, [role="alert"]')).toBeVisible()
  })

  test('logout works', async ({ page }) => {
    // Login first
    await page.fill('input[type="email"]', 'admin@test.local')
    await page.fill('input[type="password"]', process.env.TEST_USER_PASSWORD!)
    await page.click('button:has-text("Sign In")')
    
    // Wait for logged in state
    await expect(page.locator('table, [data-testid="inventory"]')).toBeVisible({ timeout: 10000 })
    
    // Click logout
    await page.click('[data-testid="user-menu"], .user-menu, .profile-dropdown')
    await page.click('text=Sign Out, text=Logout, text=Log out')
    
    // Should see login again
    await expect(page.locator('text=Sign In')).toBeVisible()
  })
})
```

### tests/e2e/permissions-ui.spec.ts

```typescript
import { test, expect, Page } from '@playwright/test'

// Helper to login
async function loginAs(page: Page, email: string) {
  await page.goto('/')
  await page.fill('input[type="email"]', email)
  await page.fill('input[type="password"]', process.env.TEST_USER_PASSWORD!)
  await page.click('button:has-text("Sign In")')
  await page.waitForSelector('table, [data-testid="inventory"]', { timeout: 10000 })
}

test.describe('Permission-Based UI', () => {
  
  test('admin sees all control buttons', async ({ page }) => {
    await loginAs(page, 'admin@test.local')
    
    // Should see add button
    await expect(page.locator('.add-btn, [data-action="add"], button:has-text("Add")')).toBeVisible()
    
    // Should see delete buttons (at least one)
    await expect(page.locator('.delete-btn, [data-action="delete"]').first()).toBeVisible()
    
    // Should see invite button
    await expect(page.locator('.invite-btn, [data-action="invite"], button:has-text("Invite")')).toBeVisible()
  })

  test('member sees add but not delete buttons', async ({ page }) => {
    await loginAs(page, 'member@test.local')
    
    // Should see add button
    await expect(page.locator('.add-btn, [data-action="add"], button:has-text("Add")')).toBeVisible()
    
    // Should NOT see delete buttons
    await expect(page.locator('.delete-btn, [data-action="delete"]')).not.toBeVisible()
    
    // Should NOT see invite button
    await expect(page.locator('.invite-btn, [data-action="invite"], button:has-text("Invite")')).not.toBeVisible()
  })

  test('viewer sees no action buttons', async ({ page }) => {
    await loginAs(page, 'viewer@test.local')
    
    // Should NOT see add button
    await expect(page.locator('.add-btn, [data-action="add"], button:has-text("Add")')).not.toBeVisible()
    
    // Should NOT see delete buttons
    await expect(page.locator('.delete-btn, [data-action="delete"]')).not.toBeVisible()
    
    // Should NOT see edit buttons
    await expect(page.locator('.edit-btn, [data-action="edit"]')).not.toBeVisible()
    
    // Should still see the inventory data
    await expect(page.locator('table tbody tr').first()).toBeVisible()
  })

  test('super user sees company switcher', async ({ page }) => {
    await loginAs(page, 'super@test.local')
    
    // Should see company switcher
    await expect(page.locator('#companySwitcher, [data-testid="company-switcher"]')).toBeVisible()
    
    // Should see admin dashboard link/button
    await expect(page.locator('[data-super-only], text=Admin Dashboard, text=Platform')).toBeVisible()
  })

  test('admin does not see company switcher', async ({ page }) => {
    await loginAs(page, 'admin@test.local')
    
    // Should NOT see company switcher (single company per user)
    await expect(page.locator('#companySwitcher, [data-testid="company-switcher"]')).not.toBeVisible()
  })
})
```

### tests/e2e/inventory-crud.spec.ts

```typescript
import { test, expect, Page } from '@playwright/test'

async function loginAs(page: Page, email: string) {
  await page.goto('/')
  await page.fill('input[type="email"]', email)
  await page.fill('input[type="password"]', process.env.TEST_USER_PASSWORD!)
  await page.click('button:has-text("Sign In")')
  await page.waitForSelector('table, [data-testid="inventory"]', { timeout: 10000 })
}

test.describe('Inventory CRUD Operations', () => {
  const testItemName = `E2E Test Item ${Date.now()}`

  test.beforeEach(async ({ page }) => {
    await loginAs(page, 'admin@test.local')
  })

  test('can create new item', async ({ page }) => {
    // Click add button
    await page.click('.add-btn, [data-action="add"], button:has-text("Add")')
    
    // Fill form
    await page.fill('[name="name"], #itemName', testItemName)
    await page.fill('[name="quantity"], #itemQuantity', '100')
    await page.fill('[name="sku"], #itemSku', `E2E-${Date.now()}`)
    
    // Save
    await page.click('button:has-text("Save"), button[type="submit"]')
    
    // Verify item appears in table
    await expect(page.locator(`text=${testItemName}`)).toBeVisible({ timeout: 5000 })
  })

  test('can edit existing item', async ({ page }) => {
    // Find and click edit on first item
    await page.click('tr:first-child .edit-btn, tr:first-child [data-action="edit"]')
    
    // Modify quantity
    const quantityInput = page.locator('[name="quantity"], #itemQuantity')
    await quantityInput.clear()
    await quantityInput.fill('999')
    
    // Save
    await page.click('button:has-text("Save"), button[type="submit"]')
    
    // Verify change
    await expect(page.locator('text=999')).toBeVisible()
  })

  test('soft delete moves item to trash', async ({ page }) => {
    // Get first item's name
    const firstItemName = await page.locator('tr:first-child td:first-child').textContent()
    
    // Click delete
    await page.click('tr:first-child .delete-btn, tr:first-child [data-action="delete"]')
    
    // Confirm if dialog appears
    const confirmButton = page.locator('button:has-text("Confirm"), button:has-text("Delete")')
    if (await confirmButton.isVisible()) {
      await confirmButton.click()
    }
    
    // Verify success message
    await expect(page.locator('text=trash, text=deleted')).toBeVisible({ timeout: 5000 })
    
    // Item should not be in main list
    await expect(page.locator(`td:has-text("${firstItemName}")`)).not.toBeVisible()
  })

  test('viewer cannot modify items', async ({ page }) => {
    // Logout and login as viewer
    await page.click('[data-testid="user-menu"], .user-menu')
    await page.click('text=Sign Out, text=Logout')
    await loginAs(page, 'viewer@test.local')
    
    // Verify no edit buttons
    await expect(page.locator('.edit-btn, [data-action="edit"]')).not.toBeVisible()
    
    // Verify no delete buttons
    await expect(page.locator('.delete-btn, [data-action="delete"]')).not.toBeVisible()
  })
})
```

### tests/setup/playwright-setup.ts

```typescript
import { FullConfig } from '@playwright/test'
import globalSetup from './global-setup'

async function playwrightGlobalSetup(config: FullConfig) {
  console.log('🎭 Playwright global setup')
  await globalSetup()
}

export default playwrightGlobalSetup
```

### tests/setup/playwright-teardown.ts

```typescript
import { FullConfig } from '@playwright/test'
import globalTeardown from './global-teardown'

async function playwrightGlobalTeardown(config: FullConfig) {
  console.log('🎭 Playwright global teardown')
  await globalTeardown()
}

export default playwrightGlobalTeardown
```

---

## CI/CD Pipeline

### .github/workflows/test.yml

```yaml
name: Test Suite

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  SUPABASE_URL: ${{ secrets.SUPABASE_TEST_URL }}
  SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_TEST_ANON_KEY }}
  SUPABASE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_TEST_SERVICE_KEY }}
  TEST_USER_PASSWORD: ${{ secrets.TEST_USER_PASSWORD }}
  TEST_APP_URL: http://localhost:3000

jobs:
  # ===========================================================================
  # Unit & Integration Tests
  # ===========================================================================
  test-unit-integration:
    name: Unit & Integration Tests
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      
      - name: Install dependencies
        run: npm ci
      
      - name: Run unit tests
        run: npm run test:unit
      
      - name: Run integration tests
        run: npm run test:integration
      
      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: ./coverage/coverage-final.json
          fail_ci_if_error: false

  # ===========================================================================
  # E2E Tests
  # ===========================================================================
  test-e2e:
    name: E2E Tests
    runs-on: ubuntu-latest
    needs: test-unit-integration  # Only run if unit/integration pass
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      
      - name: Install dependencies
        run: npm ci
      
      - name: Install Playwright browsers
        run: npx playwright install chromium --with-deps
      
      - name: Run E2E tests
        run: npm run test:e2e
      
      - name: Upload Playwright report
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7
      
      - name: Upload test videos
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: test-videos
          path: test-results/
          retention-days: 7

  # ===========================================================================
  # Security Audit
  # ===========================================================================
  security-audit:
    name: Security Audit
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      
      - name: Install dependencies
        run: npm ci
      
      - name: Run npm audit
        run: npm audit --audit-level=high
        continue-on-error: true  # Don't fail on vulnerabilities (review manually)
      
      - name: Check for secrets in code
        uses: trufflesecurity/trufflehog@main
        with:
          path: ./
          base: ${{ github.event.repository.default_branch }}
          head: HEAD

  # ===========================================================================
  # Deploy (only on main, after tests pass)
  # ===========================================================================
  deploy:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs: [test-unit-integration, test-e2e]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      
      - name: Deploy to Cloudflare Pages
        uses: cloudflare/pages-action@v1
        with:
          apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          accountId: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          projectName: inventory-manager
          directory: src
          gitHubToken: ${{ secrets.GITHUB_TOKEN }}
```

---

## Running Tests

### Local Development

```bash
# Start local Supabase (if using local)
npm run supabase:start

# Run all unit and integration tests
npm run test:run

# Run tests in watch mode (during development)
npm run test

# Run only unit tests
npm run test:unit

# Run only integration tests (requires Supabase)
npm run test:integration

# Run with coverage report
npm run test:coverage

# Run E2E tests (starts dev server automatically)
npm run test:e2e

# Run E2E tests with UI (for debugging)
npm run test:e2e:ui

# Run E2E tests in headed browser (see what's happening)
npm run test:e2e:headed

# Run everything
npm run test:all
```

### Test Environment Setup

```bash
# First time setup - create test users and data
npm run test:setup

# Cleanup test data (run if tests leave stale data)
npm run test:teardown

# Reset Supabase (drops and recreates DB)
npm run supabase:reset
```

### Debugging Failed Tests

```bash
# Run specific test file
npx vitest run tests/integration/rls/inventory-items.test.ts

# Run tests matching pattern
npx vitest run -t "admin can soft delete"

# Run with verbose output
npx vitest run --reporter=verbose

# E2E: Run specific test file
npx playwright test tests/e2e/auth.spec.ts

# E2E: Debug mode (step through)
npx playwright test --debug

# E2E: Show browser
npx playwright test --headed

# E2E: Generate test (record actions)
npx playwright codegen http://localhost:3000
```

---

## Summary

### What This Sets Up

| Component | Purpose |
|-----------|---------|
| **Vitest** | Unit and integration test runner |
| **Playwright** | E2E browser testing |
| **Test Users** | 5 users across 2 companies with different roles |
| **Global Setup/Teardown** | Creates/cleans test data automatically |
| **GitHub Actions** | CI/CD pipeline runs tests on every push |
| **Coverage Reports** | Track what's tested |

### Test Categories

| Category | Files | What's Tested |
|----------|-------|---------------|
| Unit | `tests/unit/*.test.ts` | Utility functions, permission helpers |
| RLS | `tests/integration/rls/*.test.ts` | Row-level security policies |
| RPC | `tests/integration/rpc/*.test.ts` | Server-side functions |
| Security | `tests/integration/security/*.test.ts` | Privilege escalation, cross-tenant |
| E2E | `tests/e2e/*.spec.ts` | Full user workflows |

### Next Steps

1. **Run Phase 0** — Set up testing infrastructure
2. **Run Phase 1** — Implement multi-tenancy with tests alongside
3. **Verify all security tests pass** before deploying

---

## Quick Reference

```bash
# Install everything
npm install -D vitest @vitest/coverage-v8 @supabase/supabase-js jsdom @testing-library/dom @playwright/test typescript @types/node dotenv
npx playwright install chromium

# Create test environment
cp .env.example .env.test
# Edit .env.test with test credentials

# Run tests
npm run test:run      # Unit + Integration
npm run test:e2e      # E2E
npm run test:coverage # With coverage
```
