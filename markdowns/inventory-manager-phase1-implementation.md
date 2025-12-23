# Inventory Manager: Phase 1 Implementation Guide
## Multi-Tenant SaaS Architecture, RBAC, and Data Protection

**Version:** 1.0  
**Date:** December 2024  
**Production URL:** `https://inventory.modulus-software.com`  
**Supabase Project:** Inventory Manager

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State Analysis](#current-state-analysis)
3. [Target Architecture](#target-architecture)
4. [User Hierarchy & Permissions](#user-hierarchy--permissions)
5. [Database Schema](#database-schema)
6. [SQL Migration](#sql-migration)
7. [Frontend Implementation](#frontend-implementation)
8. [Testing Checklist](#testing-checklist)
9. [Rollout Plan](#rollout-plan)

---

## Executive Summary

Phase 1 transforms Inventory Manager from a single-tenant application into a fully-featured multi-tenant B2B SaaS platform with:

- **Multi-Company Architecture** — Complete data isolation between customer businesses
- **Role-Based Access Control (RBAC)** — Super User, Admin, Member, Viewer roles
- **Invitation-Only Access** — No public signup, login-only interface
- **Comprehensive Data Protection** — Soft deletes, audit logging, snapshots, point-in-time recovery
- **Super User Dashboard** — Platform-wide management, metrics, and administration

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Terminology | "Company" not "Organization" | Each tenant is a separate business |
| Signup Model | Invitation-only | Matches B2B security requirements |
| Delete Strategy | Soft delete + audit log | Enable recovery, maintain history |
| UI Approach | Hide unavailable actions | Don't show then error — hide buttons |
| Super User | Single platform owner (Brandon) | Full visibility across all companies |

---

## Current State Analysis

### Existing Tables

| Table | Purpose | Migration Action |
|-------|---------|------------------|
| `items` | Inventory items | → `inventory_items` with `company_id` |
| `profiles` | User profile data | Keep, add preferences |
| `authorized_users` | Access allow-list | → `company_members` |
| `orders` | Order history | Add `company_id` |
| `order_recipients` | Email autocomplete | Add `company_id` |

### Current Auth Model
- Users sign in via Supabase Auth
- `authorized_users` table controls access (simple allow-list)
- All authorized users see the **same shared data**
- No company/tenant isolation exists

### Current Frontend Query Patterns
```javascript
// Items
SB.client.from('items').select('*')
SB.client.from('items').insert([...])
SB.client.from('items').update({...}).eq('id', id)
SB.client.from('items').delete().eq('id', id)

// These need to change to:
// 1. Use 'inventory_items' table
// 2. Filter by company_id
// 3. Use soft delete RPC instead of hard delete
```

---

## Target Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         INVENTORY MANAGER                            │
│                      Multi-Tenant SaaS Platform                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │  Company A  │    │  Company B  │    │  Company C  │             │
│  │  (Oakley)   │    │  (Future)   │    │  (Future)   │             │
│  ├─────────────┤    ├─────────────┤    ├─────────────┤             │
│  │ • Admin     │    │ • Admin     │    │ • Admin     │             │
│  │ • Members   │    │ • Members   │    │ • Members   │             │
│  │ • Inventory │    │ • Inventory │    │ • Inventory │             │
│  │ • Orders    │    │ • Orders    │    │ • Orders    │             │
│  └─────────────┘    └─────────────┘    └─────────────┘             │
│         │                 │                  │                      │
│         └─────────────────┼──────────────────┘                      │
│                           │                                         │
│                    ┌──────▼──────┐                                  │
│                    │ SUPER USER  │                                  │
│                    │  (Brandon)  │                                  │
│                    │ Sees ALL    │                                  │
│                    └─────────────┘                                  │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  DATA PROTECTION LAYER                                               │
│  • Soft Deletes (never lose data)                                   │
│  • Audit Log (track every change)                                   │
│  • Snapshots (point-in-time backup)                                 │
│  • Recovery Tools (undo, restore)                                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## User Hierarchy & Permissions

### Role Definitions

| Role | Scope | Description |
|------|-------|-------------|
| **Super User** | Platform-wide | Platform owner (Brandon). Sees all companies, full control |
| **Admin** | Single company | Company administrator. Manages users, full CRUD |
| **Member** | Single company | Standard user. Create, read, update — NO delete |
| **Viewer** | Single company | Read-only access |

### Permission Matrix

| Action | Super User | Admin | Member | Viewer |
|--------|------------|-------|--------|--------|
| View inventory | ✅ All companies | ✅ Own company | ✅ | ✅ |
| Add items | ✅ | ✅ | ✅ | ❌ |
| Edit items | ✅ | ✅ | ✅ | ❌ |
| Delete items | ✅ | ✅ | ❌ | ❌ |
| View orders | ✅ | ✅ | ✅ | ✅ |
| Create orders | ✅ | ✅ | ✅ | ❌ |
| Delete orders | ✅ | ✅ | ❌ | ❌ |
| Invite users | ✅ | ✅ | ❌ | ❌ |
| Manage users | ✅ All | ✅ Own company | ❌ | ❌ |
| View other companies | ✅ | ❌ | ❌ | ❌ |
| Create companies | ✅ | ❌ | ❌ | ❌ |
| View platform metrics | ✅ | ❌ | ❌ | ❌ |
| Restore snapshots | ✅ | ❌ | ❌ | ❌ |
| Undo any action | ✅ | ❌ | ❌ | ❌ |
| View audit log | ✅ | ✅ Own company | ❌ | ❌ |
| View trash | ✅ | ✅ | ❌ | ❌ |
| Restore from trash | ✅ | ✅ | ❌ | ❌ |

### UI Element Visibility

| UI Element | Super User | Admin | Member | Viewer |
|------------|------------|-------|--------|--------|
| Delete button (trash icon) | ✅ Show | ✅ Show | ❌ **Hide** | ❌ **Hide** |
| Add item button | ✅ Show | ✅ Show | ✅ Show | ❌ **Hide** |
| Edit button | ✅ Show | ✅ Show | ✅ Show | ❌ **Hide** |
| Invite user button | ✅ Show | ✅ Show | ❌ **Hide** | ❌ **Hide** |
| Super Admin Dashboard | ✅ Show | ❌ **Hide** | ❌ **Hide** | ❌ **Hide** |
| Company switcher | ✅ Show | ❌ **Hide** | ❌ **Hide** | ❌ **Hide** |
| Recovery tools | ✅ Show | ✅ Show | ❌ **Hide** | ❌ **Hide** |

---

## Database Schema

### Complete Schema Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CORE TENANCY                                │
├─────────────────────────────────────────────────────────────────────┤
│  companies              │  profiles              │  company_        │
│  ─────────              │  ────────              │  members         │
│  id (PK)                │  id (PK, FK→auth.users)│  ────────────    │
│  name                   │  email                 │  id (PK)         │
│  slug (unique)          │  full_name             │  company_id (FK) │
│  settings (JSONB)       │  avatar_url            │  user_id (FK)    │
│  is_active              │  phone                 │  role            │
│  created_at             │  delivery_address      │  is_super_user   │
│  updated_at             │  preferences (JSONB)   │  assigned_admin  │
│                         │  created_at            │  created_at      │
│                         │  updated_at            │  updated_at      │
├─────────────────────────────────────────────────────────────────────┤
│                         INVITATIONS & REQUESTS                      │
├─────────────────────────────────────────────────────────────────────┤
│  invitations            │  role_change_requests                     │
│  ───────────            │  ─────────────────────                    │
│  id (PK)                │  id (PK)                                  │
│  company_id (FK)        │  company_id (FK)                          │
│  email                  │  user_id (FK)                             │
│  role                   │  current_role                             │
│  token (unique)         │  requested_role                           │
│  invited_by (FK)        │  reason                                   │
│  expires_at             │  status                                   │
│  accepted_at            │  reviewed_by, reviewed_at                 │
├─────────────────────────────────────────────────────────────────────┤
│                      INVENTORY DOMAIN                               │
├─────────────────────────────────────────────────────────────────────┤
│  inventory_items        │  inventory_            │  inventory_      │
│  ───────────────        │  transactions          │  locations       │
│  id (PK)                │  ──────────────        │  ──────────      │
│  company_id (FK)        │  id (PK)               │  id (PK)         │
│  name                   │  company_id (FK)       │  company_id (FK) │
│  description            │  item_id (FK)          │  name            │
│  quantity               │  transaction_type      │  address         │
│  sku                    │  quantity_change       │  is_active       │
│  low_stock_qty          │  quantity_before       │  deleted_at      │
│  reorder_enabled        │  quantity_after        │  deleted_by      │
│  unit_cost              │  notes                 │                  │
│  image_url              │  created_by            │                  │
│  metadata (JSONB)       │  created_at            │                  │
│  deleted_at ⬅️ SOFT     │                        │                  │
│  deleted_by             │                        │                  │
│  created_at             │                        │                  │
│  updated_at             │                        │                  │
├─────────────────────────────────────────────────────────────────────┤
│  inventory_categories   │  orders                │  order_          │
│  ────────────────────   │  ──────                │  recipients      │
│  id (PK)                │  id (PK)               │  ────────────    │
│  company_id (FK)        │  company_id (FK)       │  id (PK)         │
│  name                   │  ... existing cols     │  company_id (FK) │
│  description            │  deleted_at            │  email           │
│  parent_category_id     │  deleted_by            │  name            │
│  deleted_at             │  created_at            │  created_at      │
│  deleted_by             │                        │                  │
├─────────────────────────────────────────────────────────────────────┤
│                      DATA PROTECTION                                │
├─────────────────────────────────────────────────────────────────────┤
│  audit_log              │  inventory_snapshots   │  action_metrics  │
│  ─────────              │  ───────────────────   │  ──────────────  │
│  id (PK)                │  id (PK)               │  id (PK)         │
│  action                 │  company_id (FK)       │  company_id (FK) │
│  table_name             │  name                  │  user_id (FK)    │
│  record_id              │  description           │  metric_date     │
│  company_id (FK)        │  snapshot_type         │  action_type     │
│  user_id (FK)           │  items_data (JSONB)    │  table_name      │
│  user_email             │  items_count           │  action_count    │
│  user_role              │  total_quantity        │  records_affected│
│  old_values (JSONB)     │  created_at            │  quantity_removed│
│  new_values (JSONB)     │  created_by            │  quantity_added  │
│  changed_fields         │  restored_at           │                  │
│  rolled_back_at         │  restored_by           │                  │
│  rolled_back_by         │                        │                  │
│  created_at             │                        │                  │
├─────────────────────────────────────────────────────────────────────┤
│                      PLATFORM MANAGEMENT                            │
├─────────────────────────────────────────────────────────────────────┤
│  role_configurations                                                │
│  ───────────────────                                                │
│  id (PK)                                                            │
│  role_name (admin, member, viewer)                                  │
│  permissions (JSONB)                                                │
│  description                                                        │
│  updated_at                                                         │
│  updated_by (FK)                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## SQL Migration

Create file: `supabase/migrations/002_phase1_multitenancy.sql`

```sql
-- ============================================================================
-- INVENTORY MANAGER: PHASE 1 - MULTI-TENANT SAAS MIGRATION
-- ============================================================================
-- This migration implements:
-- 1. Multi-company (tenant) architecture
-- 2. Role-based access control (RBAC)
-- 3. Invitation-only user onboarding
-- 4. Comprehensive data protection (soft deletes, audit log, snapshots)
-- 5. Super user platform management
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1: CORE MULTI-TENANCY TABLES
-- ============================================================================

-- 1.1 Companies table (tenants)
CREATE TABLE IF NOT EXISTS public.companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    settings JSONB DEFAULT '{}'::jsonb,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_companies_slug ON public.companies(slug);
CREATE INDEX IF NOT EXISTS idx_companies_active ON public.companies(is_active);

COMMENT ON TABLE public.companies IS 'Customer companies (tenants) - each is a separate business';
COMMENT ON COLUMN public.companies.slug IS 'URL-friendly unique identifier';
COMMENT ON COLUMN public.companies.settings IS 'Company-specific configuration';

-- 1.2 Company members (users belonging to companies)
CREATE TABLE IF NOT EXISTS public.company_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member', 'viewer')),
    is_super_user BOOLEAN DEFAULT false,
    assigned_admin_id UUID REFERENCES auth.users(id),
    invited_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    
    UNIQUE(company_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_company_members_company ON public.company_members(company_id);
CREATE INDEX IF NOT EXISTS idx_company_members_user ON public.company_members(user_id);
CREATE INDEX IF NOT EXISTS idx_company_members_super ON public.company_members(is_super_user) WHERE is_super_user = true;
CREATE INDEX IF NOT EXISTS idx_company_members_admin ON public.company_members(assigned_admin_id);

COMMENT ON TABLE public.company_members IS 'Links users to companies with roles';
COMMENT ON COLUMN public.company_members.is_super_user IS 'Platform owner - can see all companies';
COMMENT ON COLUMN public.company_members.assigned_admin_id IS 'Admin responsible for this user';

-- 1.3 Invitations table
CREATE TABLE IF NOT EXISTS public.invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member', 'viewer')),
    token TEXT UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
    invited_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ DEFAULT (now() + interval '7 days'),
    accepted_at TIMESTAMPTZ,
    
    UNIQUE(company_id, email)
);

CREATE INDEX IF NOT EXISTS idx_invitations_token ON public.invitations(token);
CREATE INDEX IF NOT EXISTS idx_invitations_email ON public.invitations(email);

COMMENT ON TABLE public.invitations IS 'Pending invitations to join companies';

-- 1.4 Role change requests
CREATE TABLE IF NOT EXISTS public.role_change_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    current_role TEXT NOT NULL,
    requested_role TEXT NOT NULL CHECK (requested_role IN ('admin', 'member', 'viewer')),
    reason TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
    reviewed_by UUID REFERENCES auth.users(id),
    reviewed_at TIMESTAMPTZ,
    admin_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_role_requests_company ON public.role_change_requests(company_id);
CREATE INDEX IF NOT EXISTS idx_role_requests_status ON public.role_change_requests(status) WHERE status = 'pending';

COMMENT ON TABLE public.role_change_requests IS 'User requests to change their role';

-- 1.5 Role configurations (customizable permissions)
CREATE TABLE IF NOT EXISTS public.role_configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name TEXT NOT NULL UNIQUE CHECK (role_name IN ('admin', 'member', 'viewer')),
    permissions JSONB NOT NULL DEFAULT '{}'::jsonb,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    updated_by UUID REFERENCES auth.users(id)
);

-- Insert default role configurations
INSERT INTO public.role_configurations (role_name, permissions, description) VALUES
    ('admin', '{"can_read": true, "can_create": true, "can_update": true, "can_delete": true, "can_invite": true, "can_manage_users": true}', 'Company administrator - full access within company'),
    ('member', '{"can_read": true, "can_create": true, "can_update": true, "can_delete": false, "can_invite": false, "can_manage_users": false}', 'Standard user - create, read, update only'),
    ('viewer', '{"can_read": true, "can_create": false, "can_update": false, "can_delete": false, "can_invite": false, "can_manage_users": false}', 'Read-only access')
ON CONFLICT (role_name) DO NOTHING;

-- ============================================================================
-- SECTION 2: INVENTORY DOMAIN TABLES
-- ============================================================================

-- 2.1 Inventory locations
CREATE TABLE IF NOT EXISTS public.inventory_locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    address TEXT,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_inventory_locations_company ON public.inventory_locations(company_id);
CREATE INDEX IF NOT EXISTS idx_inventory_locations_active ON public.inventory_locations(company_id) WHERE deleted_at IS NULL;

-- 2.2 Inventory categories
CREATE TABLE IF NOT EXISTS public.inventory_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    parent_category_id UUID REFERENCES public.inventory_categories(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_inventory_categories_company ON public.inventory_categories(company_id);
CREATE INDEX IF NOT EXISTS idx_inventory_categories_active ON public.inventory_categories(company_id) WHERE deleted_at IS NULL;

-- 2.3 Inventory items (replaces `items` table)
CREATE TABLE IF NOT EXISTS public.inventory_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    quantity INTEGER NOT NULL DEFAULT 0,
    sku TEXT,
    category_id UUID REFERENCES public.inventory_categories(id),
    location_id UUID REFERENCES public.inventory_locations(id),
    unit_of_measure TEXT DEFAULT 'each',
    reorder_point INTEGER,
    reorder_quantity INTEGER,
    unit_cost DECIMAL(10,2),
    sale_price DECIMAL(10,2),
    barcode TEXT,
    image_url TEXT,
    is_active BOOLEAN DEFAULT true,
    low_stock_qty INTEGER,
    reorder_enabled BOOLEAN DEFAULT false,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES auth.users(id),
    
    UNIQUE(company_id, sku)
);

CREATE INDEX IF NOT EXISTS idx_inventory_items_company ON public.inventory_items(company_id);
CREATE INDEX IF NOT EXISTS idx_inventory_items_active ON public.inventory_items(company_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_items_deleted ON public.inventory_items(company_id, deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_items_sku ON public.inventory_items(company_id, sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_items_barcode ON public.inventory_items(company_id, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_items_low_stock ON public.inventory_items(company_id, quantity, low_stock_qty) WHERE low_stock_qty IS NOT NULL AND deleted_at IS NULL;

-- Case-insensitive name uniqueness within company
CREATE UNIQUE INDEX IF NOT EXISTS idx_inventory_items_name_ci ON public.inventory_items(company_id, lower(name)) WHERE deleted_at IS NULL;

-- 2.4 Inventory transactions (audit log for quantity changes)
CREATE TABLE IF NOT EXISTS public.inventory_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('received', 'sold', 'adjusted', 'transferred', 'returned', 'damaged', 'initial')),
    quantity_change INTEGER NOT NULL,
    quantity_before INTEGER NOT NULL,
    quantity_after INTEGER NOT NULL,
    from_location_id UUID REFERENCES public.inventory_locations(id),
    to_location_id UUID REFERENCES public.inventory_locations(id),
    reference_number TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_inventory_transactions_company ON public.inventory_transactions(company_id);
CREATE INDEX IF NOT EXISTS idx_inventory_transactions_item ON public.inventory_transactions(item_id);
CREATE INDEX IF NOT EXISTS idx_inventory_transactions_date ON public.inventory_transactions(company_id, created_at DESC);

-- ============================================================================
-- SECTION 3: DATA PROTECTION TABLES
-- ============================================================================

-- 3.1 Audit log (tracks ALL changes)
CREATE TABLE IF NOT EXISTS public.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- What happened
    action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'RESTORE', 'BULK_DELETE', 'ROLLBACK')),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    
    -- Who did it
    company_id UUID REFERENCES public.companies(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id),
    user_email TEXT,
    user_role TEXT,
    
    -- What changed
    old_values JSONB,
    new_values JSONB,
    changed_fields TEXT[],
    
    -- Context
    reason TEXT,
    ip_address TEXT,
    user_agent TEXT,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT now(),
    
    -- Rollback tracking
    rolled_back_at TIMESTAMPTZ,
    rolled_back_by UUID REFERENCES auth.users(id),
    rollback_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_log_company ON public.audit_log(company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_table ON public.audit_log(table_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_record ON public.audit_log(record_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_user ON public.audit_log(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON public.audit_log(action, created_at DESC);

COMMENT ON TABLE public.audit_log IS 'Complete audit trail of all data changes for recovery and compliance';

-- 3.2 Inventory snapshots (point-in-time backups)
CREATE TABLE IF NOT EXISTS public.inventory_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    
    -- Snapshot metadata
    name TEXT NOT NULL,
    description TEXT,
    snapshot_type TEXT NOT NULL CHECK (snapshot_type IN ('auto_daily', 'auto_weekly', 'manual', 'pre_import', 'pre_bulk_delete')),
    
    -- The actual data
    items_data JSONB NOT NULL,
    items_count INTEGER NOT NULL,
    total_quantity INTEGER NOT NULL,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    
    -- Restore tracking
    restored_at TIMESTAMPTZ,
    restored_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_snapshots_company ON public.inventory_snapshots(company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_snapshots_type ON public.inventory_snapshots(company_id, snapshot_type);

COMMENT ON TABLE public.inventory_snapshots IS 'Point-in-time snapshots of inventory for disaster recovery';

-- 3.3 Action metrics (aggregate tracking of destructive actions)
CREATE TABLE IF NOT EXISTS public.action_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID REFERENCES public.companies(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id),
    
    -- Metric type
    metric_date DATE NOT NULL DEFAULT CURRENT_DATE,
    action_type TEXT NOT NULL CHECK (action_type IN ('delete', 'bulk_delete', 'update', 'restore', 'rollback')),
    table_name TEXT NOT NULL,
    
    -- Counts
    action_count INTEGER NOT NULL DEFAULT 1,
    records_affected INTEGER NOT NULL DEFAULT 1,
    
    -- For quantity changes
    quantity_removed INTEGER DEFAULT 0,
    quantity_added INTEGER DEFAULT 0,
    
    UNIQUE(company_id, user_id, metric_date, action_type, table_name)
);

CREATE INDEX IF NOT EXISTS idx_action_metrics_company ON public.action_metrics(company_id, metric_date DESC);
CREATE INDEX IF NOT EXISTS idx_action_metrics_user ON public.action_metrics(user_id, metric_date DESC);

-- ============================================================================
-- SECTION 4: MODIFY EXISTING TABLES
-- ============================================================================

-- 4.1 Add preferences to profiles
ALTER TABLE public.profiles 
    ADD COLUMN IF NOT EXISTS preferences JSONB DEFAULT '{}'::jsonb;

-- 4.2 Add soft delete and company_id to orders
ALTER TABLE public.orders 
    ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES public.companies(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS idx_orders_company ON public.orders(company_id);
CREATE INDEX IF NOT EXISTS idx_orders_active ON public.orders(company_id) WHERE deleted_at IS NULL;

-- 4.3 Add company_id to order_recipients
ALTER TABLE public.order_recipients 
    ADD COLUMN IF NOT EXISTS company_id UUID REFERENCES public.companies(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_order_recipients_company ON public.order_recipients(company_id);

-- ============================================================================
-- SECTION 5: HELPER FUNCTIONS
-- ============================================================================

-- 5.1 Check if user is super user
CREATE OR REPLACE FUNCTION public.is_super_user()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.company_members 
        WHERE user_id = auth.uid() AND is_super_user = true
    )
$$;

-- 5.2 Get user's company IDs (super users see all)
CREATE OR REPLACE FUNCTION public.get_user_company_ids()
RETURNS SETOF UUID
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF public.is_super_user() THEN
        RETURN QUERY SELECT id FROM public.companies WHERE is_active = true;
    ELSE
        RETURN QUERY 
            SELECT company_id 
            FROM public.company_members 
            WHERE user_id = auth.uid();
    END IF;
END;
$$;

-- 5.3 Get user's role in a company
CREATE OR REPLACE FUNCTION public.get_user_role(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_role TEXT;
    v_is_super BOOLEAN;
BEGIN
    SELECT is_super_user INTO v_is_super
    FROM public.company_members
    WHERE user_id = auth.uid()
    LIMIT 1;
    
    IF v_is_super THEN
        RETURN 'super_user';
    END IF;
    
    SELECT role INTO v_role
    FROM public.company_members
    WHERE user_id = auth.uid() AND company_id = p_company_id;
    
    RETURN v_role;
END;
$$;

-- 5.4 Check if user can delete (admin or super user)
CREATE OR REPLACE FUNCTION public.user_can_delete(p_company_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT public.is_super_user() OR EXISTS (
        SELECT 1 FROM public.company_members
        WHERE user_id = auth.uid() 
        AND company_id = p_company_id 
        AND role = 'admin'
    )
$$;

-- 5.5 Check if user can write (admin, member, or super user)
CREATE OR REPLACE FUNCTION public.user_can_write(p_company_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT public.is_super_user() OR EXISTS (
        SELECT 1 FROM public.company_members
        WHERE user_id = auth.uid() 
        AND company_id = p_company_id 
        AND role IN ('admin', 'member')
    )
$$;

-- 5.6 Check if user can invite (admin or super user)
CREATE OR REPLACE FUNCTION public.user_can_invite(p_company_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT public.is_super_user() OR EXISTS (
        SELECT 1 FROM public.company_members
        WHERE user_id = auth.uid() 
        AND company_id = p_company_id 
        AND role = 'admin'
    )
$$;

-- 5.7 Get user's full permissions for a company
CREATE OR REPLACE FUNCTION public.get_my_permissions(p_company_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_role TEXT;
    v_is_super BOOLEAN;
    v_assigned_admin_id UUID;
    v_assigned_admin_email TEXT;
    v_permissions JSONB;
BEGIN
    -- Check super user status
    SELECT cm.is_super_user, cm.role, cm.assigned_admin_id
    INTO v_is_super, v_role, v_assigned_admin_id
    FROM public.company_members cm
    WHERE cm.user_id = auth.uid() 
    AND (cm.company_id = p_company_id OR cm.is_super_user = true)
    LIMIT 1;
    
    -- Get assigned admin email
    IF v_assigned_admin_id IS NOT NULL THEN
        SELECT email INTO v_assigned_admin_email
        FROM auth.users WHERE id = v_assigned_admin_id;
    END IF;
    
    -- Super user has all permissions
    IF v_is_super THEN
        RETURN json_build_object(
            'role', 'super_user',
            'is_super_user', true,
            'can_read', true,
            'can_create', true,
            'can_update', true,
            'can_delete', true,
            'can_invite', true,
            'can_manage_users', true,
            'can_view_all_companies', true,
            'can_view_metrics', true,
            'can_restore_snapshots', true,
            'can_undo_actions', true,
            'assigned_admin_id', null,
            'assigned_admin_email', null
        );
    END IF;
    
    -- Get role permissions from configuration
    SELECT permissions INTO v_permissions
    FROM public.role_configurations
    WHERE role_name = v_role;
    
    IF v_role IS NULL THEN
        RETURN json_build_object(
            'role', null,
            'is_super_user', false,
            'can_read', false,
            'can_create', false,
            'can_update', false,
            'can_delete', false,
            'can_invite', false,
            'can_manage_users', false,
            'can_view_all_companies', false,
            'can_view_metrics', false,
            'can_restore_snapshots', false,
            'can_undo_actions', false,
            'assigned_admin_id', null,
            'assigned_admin_email', null
        );
    END IF;
    
    RETURN json_build_object(
        'role', v_role,
        'is_super_user', false,
        'can_read', COALESCE((v_permissions->>'can_read')::boolean, false),
        'can_create', COALESCE((v_permissions->>'can_create')::boolean, false),
        'can_update', COALESCE((v_permissions->>'can_update')::boolean, false),
        'can_delete', COALESCE((v_permissions->>'can_delete')::boolean, false),
        'can_invite', COALESCE((v_permissions->>'can_invite')::boolean, false),
        'can_manage_users', COALESCE((v_permissions->>'can_manage_users')::boolean, false),
        'can_view_all_companies', false,
        'can_view_metrics', v_role = 'admin',
        'can_restore_snapshots', false,
        'can_undo_actions', false,
        'assigned_admin_id', v_assigned_admin_id,
        'assigned_admin_email', v_assigned_admin_email
    );
END;
$$;

-- ============================================================================
-- SECTION 6: RLS POLICIES
-- ============================================================================

-- 6.1 Companies RLS
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their companies" ON public.companies;
CREATE POLICY "Users can view their companies"
    ON public.companies FOR SELECT
    USING (id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Super users can manage companies" ON public.companies;
CREATE POLICY "Super users can manage companies"
    ON public.companies FOR ALL
    USING (public.is_super_user());

-- 6.2 Company members RLS
ALTER TABLE public.company_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company members" ON public.company_members;
CREATE POLICY "Users can view company members"
    ON public.company_members FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Admins can manage members" ON public.company_members;
CREATE POLICY "Admins can manage members"
    ON public.company_members FOR ALL
    USING (public.user_can_invite(company_id));

-- 6.3 Invitations RLS
ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can manage invitations" ON public.invitations;
CREATE POLICY "Admins can manage invitations"
    ON public.invitations FOR ALL
    USING (public.user_can_invite(company_id));

-- 6.4 Role change requests RLS
ALTER TABLE public.role_change_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own requests" ON public.role_change_requests;
CREATE POLICY "Users can view own requests"
    ON public.role_change_requests FOR SELECT
    USING (user_id = auth.uid() OR public.user_can_invite(company_id));

DROP POLICY IF EXISTS "Users can create requests" ON public.role_change_requests;
CREATE POLICY "Users can create requests"
    ON public.role_change_requests FOR INSERT
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can update requests" ON public.role_change_requests;
CREATE POLICY "Admins can update requests"
    ON public.role_change_requests FOR UPDATE
    USING (public.user_can_invite(company_id));

-- 6.5 Profiles RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view profiles in their companies" ON public.profiles;
CREATE POLICY "Users can view profiles in their companies"
    ON public.profiles FOR SELECT
    USING (
        id = auth.uid() 
        OR id IN (
            SELECT user_id FROM public.company_members 
            WHERE company_id IN (SELECT public.get_user_company_ids())
        )
    );

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (id = auth.uid());

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile"
    ON public.profiles FOR INSERT
    WITH CHECK (id = auth.uid());

-- 6.6 Inventory items RLS
ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company inventory" ON public.inventory_items;
CREATE POLICY "Users can view company inventory"
    ON public.inventory_items FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can create inventory" ON public.inventory_items;
CREATE POLICY "Writers can create inventory"
    ON public.inventory_items FOR INSERT
    WITH CHECK (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Writers can update inventory" ON public.inventory_items;
CREATE POLICY "Writers can update inventory"
    ON public.inventory_items FOR UPDATE
    USING (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Admins can delete inventory" ON public.inventory_items;
CREATE POLICY "Admins can delete inventory"
    ON public.inventory_items FOR DELETE
    USING (public.user_can_delete(company_id));

-- 6.7 Inventory transactions RLS
ALTER TABLE public.inventory_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company transactions" ON public.inventory_transactions;
CREATE POLICY "Users can view company transactions"
    ON public.inventory_transactions FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can create transactions" ON public.inventory_transactions;
CREATE POLICY "Writers can create transactions"
    ON public.inventory_transactions FOR INSERT
    WITH CHECK (public.user_can_write(company_id));

-- 6.8 Inventory locations RLS
ALTER TABLE public.inventory_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company locations" ON public.inventory_locations;
CREATE POLICY "Users can view company locations"
    ON public.inventory_locations FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can create locations" ON public.inventory_locations;
CREATE POLICY "Writers can create locations"
    ON public.inventory_locations FOR INSERT
    WITH CHECK (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Writers can update locations" ON public.inventory_locations;
CREATE POLICY "Writers can update locations"
    ON public.inventory_locations FOR UPDATE
    USING (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Admins can delete locations" ON public.inventory_locations;
CREATE POLICY "Admins can delete locations"
    ON public.inventory_locations FOR DELETE
    USING (public.user_can_delete(company_id));

-- 6.9 Inventory categories RLS
ALTER TABLE public.inventory_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company categories" ON public.inventory_categories;
CREATE POLICY "Users can view company categories"
    ON public.inventory_categories FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can create categories" ON public.inventory_categories;
CREATE POLICY "Writers can create categories"
    ON public.inventory_categories FOR INSERT
    WITH CHECK (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Writers can update categories" ON public.inventory_categories;
CREATE POLICY "Writers can update categories"
    ON public.inventory_categories FOR UPDATE
    USING (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Admins can delete categories" ON public.inventory_categories;
CREATE POLICY "Admins can delete categories"
    ON public.inventory_categories FOR DELETE
    USING (public.user_can_delete(company_id));

-- 6.10 Orders RLS
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company orders" ON public.orders;
CREATE POLICY "Users can view company orders"
    ON public.orders FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can create orders" ON public.orders;
CREATE POLICY "Writers can create orders"
    ON public.orders FOR INSERT
    WITH CHECK (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Writers can update orders" ON public.orders;
CREATE POLICY "Writers can update orders"
    ON public.orders FOR UPDATE
    USING (public.user_can_write(company_id));

DROP POLICY IF EXISTS "Admins can delete orders" ON public.orders;
CREATE POLICY "Admins can delete orders"
    ON public.orders FOR DELETE
    USING (public.user_can_delete(company_id));

-- 6.11 Order recipients RLS
ALTER TABLE public.order_recipients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view company recipients" ON public.order_recipients;
CREATE POLICY "Users can view company recipients"
    ON public.order_recipients FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "Writers can manage recipients" ON public.order_recipients;
CREATE POLICY "Writers can manage recipients"
    ON public.order_recipients FOR ALL
    USING (public.user_can_write(company_id));

-- 6.12 Audit log RLS (admins can view, no direct modification)
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view audit log" ON public.audit_log;
CREATE POLICY "Admins can view audit log"
    ON public.audit_log FOR SELECT
    USING (public.is_super_user() OR public.user_can_invite(company_id));

-- 6.13 Inventory snapshots RLS
ALTER TABLE public.inventory_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view snapshots" ON public.inventory_snapshots;
CREATE POLICY "Admins can view snapshots"
    ON public.inventory_snapshots FOR SELECT
    USING (public.is_super_user() OR public.user_can_delete(company_id));

DROP POLICY IF EXISTS "Admins can create snapshots" ON public.inventory_snapshots;
CREATE POLICY "Admins can create snapshots"
    ON public.inventory_snapshots FOR INSERT
    WITH CHECK (public.is_super_user() OR public.user_can_delete(company_id));

-- 6.14 Action metrics RLS (super users only)
ALTER TABLE public.action_metrics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Super users can view metrics" ON public.action_metrics;
CREATE POLICY "Super users can view metrics"
    ON public.action_metrics FOR SELECT
    USING (public.is_super_user());

-- 6.15 Role configurations RLS
ALTER TABLE public.role_configurations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read role configs" ON public.role_configurations;
CREATE POLICY "Anyone can read role configs"
    ON public.role_configurations FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Super users can update role configs" ON public.role_configurations;
CREATE POLICY "Super users can update role configs"
    ON public.role_configurations FOR UPDATE
    USING (public.is_super_user());

-- ============================================================================
-- SECTION 7: TRIGGERS
-- ============================================================================

-- 7.1 Auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', '')
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 7.2 Updated_at trigger
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- Apply updated_at triggers
DROP TRIGGER IF EXISTS update_companies_updated_at ON public.companies;
CREATE TRIGGER update_companies_updated_at
    BEFORE UPDATE ON public.companies
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_company_members_updated_at ON public.company_members;
CREATE TRIGGER update_company_members_updated_at
    BEFORE UPDATE ON public.company_members
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_profiles_updated_at ON public.profiles;
CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_inventory_items_updated_at ON public.inventory_items;
CREATE TRIGGER update_inventory_items_updated_at
    BEFORE UPDATE ON public.inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_inventory_locations_updated_at ON public.inventory_locations;
CREATE TRIGGER update_inventory_locations_updated_at
    BEFORE UPDATE ON public.inventory_locations
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_inventory_categories_updated_at ON public.inventory_categories;
CREATE TRIGGER update_inventory_categories_updated_at
    BEFORE UPDATE ON public.inventory_categories
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 7.3 Audit trigger function
CREATE OR REPLACE FUNCTION public.audit_trigger_func()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_old_values JSONB;
    v_new_values JSONB;
    v_changed_fields TEXT[];
    v_user_email TEXT;
    v_user_role TEXT;
    v_company_id UUID;
    v_action TEXT;
    v_record_id UUID;
BEGIN
    -- Get user info
    SELECT email INTO v_user_email FROM auth.users WHERE id = auth.uid();
    
    -- Determine action and record ID
    IF TG_OP = 'DELETE' THEN
        v_action := 'DELETE';
        v_record_id := OLD.id;
        v_old_values := to_jsonb(OLD);
        v_new_values := NULL;
        v_company_id := OLD.company_id;
    ELSIF TG_OP = 'UPDATE' THEN
        v_action := 'UPDATE';
        v_record_id := NEW.id;
        v_old_values := to_jsonb(OLD);
        v_new_values := to_jsonb(NEW);
        v_company_id := NEW.company_id;
        
        -- Find changed fields
        SELECT array_agg(key) INTO v_changed_fields
        FROM jsonb_each(v_new_values) n
        FULL OUTER JOIN jsonb_each(v_old_values) o USING (key)
        WHERE n.value IS DISTINCT FROM o.value
        AND key NOT IN ('updated_at');
        
    ELSIF TG_OP = 'INSERT' THEN
        v_action := 'INSERT';
        v_record_id := NEW.id;
        v_old_values := NULL;
        v_new_values := to_jsonb(NEW);
        v_company_id := NEW.company_id;
    END IF;
    
    -- Get user's role
    SELECT role INTO v_user_role
    FROM public.company_members
    WHERE user_id = auth.uid() AND company_id = v_company_id;
    
    -- Insert audit record
    INSERT INTO public.audit_log (
        action, table_name, record_id, company_id,
        user_id, user_email, user_role,
        old_values, new_values, changed_fields
    ) VALUES (
        v_action, TG_TABLE_NAME, v_record_id, v_company_id,
        auth.uid(), v_user_email, v_user_role,
        v_old_values, v_new_values, v_changed_fields
    );
    
    -- Update action metrics
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected, quantity_removed, quantity_added
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, LOWER(v_action), TG_TABLE_NAME,
        1, 1,
        CASE WHEN v_action = 'DELETE' AND TG_TABLE_NAME = 'inventory_items' THEN COALESCE((OLD.quantity)::integer, 0) ELSE 0 END,
        CASE WHEN v_action = 'INSERT' AND TG_TABLE_NAME = 'inventory_items' THEN COALESCE((NEW.quantity)::integer, 0) ELSE 0 END
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET 
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1,
        quantity_removed = action_metrics.quantity_removed + EXCLUDED.quantity_removed,
        quantity_added = action_metrics.quantity_added + EXCLUDED.quantity_added;
    
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- Apply audit triggers
DROP TRIGGER IF EXISTS audit_inventory_items ON public.inventory_items;
CREATE TRIGGER audit_inventory_items
    AFTER INSERT OR UPDATE OR DELETE ON public.inventory_items
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_inventory_locations ON public.inventory_locations;
CREATE TRIGGER audit_inventory_locations
    AFTER INSERT OR UPDATE OR DELETE ON public.inventory_locations
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_inventory_categories ON public.inventory_categories;
CREATE TRIGGER audit_inventory_categories
    AFTER INSERT OR UPDATE OR DELETE ON public.inventory_categories
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_orders ON public.orders;
CREATE TRIGGER audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();

-- ============================================================================
-- SECTION 8: RPC FUNCTIONS
-- ============================================================================

-- 8.1 Accept invitation
CREATE OR REPLACE FUNCTION public.accept_invitation(invitation_token TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invitation RECORD;
    v_admin_id UUID;
BEGIN
    SELECT * INTO v_invitation
    FROM public.invitations
    WHERE token = invitation_token
    AND expires_at > now()
    AND accepted_at IS NULL;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Invalid or expired invitation');
    END IF;
    
    IF v_invitation.email != (SELECT email FROM auth.users WHERE id = auth.uid()) THEN
        RETURN json_build_object('success', false, 'error', 'Invitation was sent to a different email');
    END IF;
    
    -- Find an admin to assign
    SELECT user_id INTO v_admin_id
    FROM public.company_members
    WHERE company_id = v_invitation.company_id AND role = 'admin'
    LIMIT 1;
    
    INSERT INTO public.company_members (company_id, user_id, role, invited_by, assigned_admin_id)
    VALUES (v_invitation.company_id, auth.uid(), v_invitation.role, v_invitation.invited_by, COALESCE(v_admin_id, v_invitation.invited_by))
    ON CONFLICT (company_id, user_id) DO NOTHING;
    
    UPDATE public.invitations SET accepted_at = now() WHERE id = v_invitation.id;
    
    RETURN json_build_object('success', true, 'company_id', v_invitation.company_id, 'role', v_invitation.role);
END;
$$;

-- 8.2 Get user's companies
CREATE OR REPLACE FUNCTION public.get_my_companies()
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT 
        c.id,
        c.name,
        c.slug,
        cm.role,
        cm.is_super_user,
        (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id)
    FROM public.companies c
    JOIN public.company_members cm ON cm.company_id = c.id
    WHERE cm.user_id = auth.uid()
    AND c.is_active = true
    ORDER BY cm.is_super_user DESC, c.name;
$$;

-- 8.3 Invite user
CREATE OR REPLACE FUNCTION public.invite_user(
    p_company_id UUID,
    p_email TEXT,
    p_role TEXT DEFAULT 'member'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token TEXT;
    v_company_name TEXT;
BEGIN
    IF NOT public.user_can_invite(p_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    IF p_role NOT IN ('admin', 'member', 'viewer') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid role');
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM public.company_members cm
        JOIN auth.users u ON u.id = cm.user_id
        WHERE cm.company_id = p_company_id AND u.email = p_email
    ) THEN
        RETURN json_build_object('success', false, 'error', 'User is already a member');
    END IF;
    
    SELECT name INTO v_company_name FROM public.companies WHERE id = p_company_id;
    
    INSERT INTO public.invitations (company_id, email, role, invited_by)
    VALUES (p_company_id, p_email, p_role, auth.uid())
    ON CONFLICT (company_id, email) 
    DO UPDATE SET 
        role = EXCLUDED.role,
        token = encode(gen_random_bytes(32), 'hex'),
        invited_by = EXCLUDED.invited_by,
        expires_at = now() + interval '7 days',
        accepted_at = NULL
    RETURNING token INTO v_token;
    
    RETURN json_build_object(
        'success', true,
        'token', v_token,
        'invite_url', 'https://inventory.modulus-software.com/?invite=' || v_token,
        'company_name', v_company_name
    );
END;
$$;

-- 8.4 Request role change
CREATE OR REPLACE FUNCTION public.request_role_change(
    p_requested_role TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_role TEXT;
    v_company_id UUID;
    v_request_id UUID;
BEGIN
    SELECT role, company_id INTO v_current_role, v_company_id
    FROM public.company_members
    WHERE user_id = auth.uid()
    LIMIT 1;
    
    IF v_current_role IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Not a member of any company');
    END IF;
    
    IF p_requested_role NOT IN ('admin', 'member', 'viewer') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid role');
    END IF;
    
    IF p_requested_role = v_current_role THEN
        RETURN json_build_object('success', false, 'error', 'You already have this role');
    END IF;
    
    IF EXISTS (SELECT 1 FROM public.role_change_requests WHERE user_id = auth.uid() AND status = 'pending') THEN
        RETURN json_build_object('success', false, 'error', 'Pending request already exists');
    END IF;
    
    INSERT INTO public.role_change_requests (company_id, user_id, current_role, requested_role, reason)
    VALUES (v_company_id, auth.uid(), v_current_role, p_requested_role, p_reason)
    RETURNING id INTO v_request_id;
    
    RETURN json_build_object('success', true, 'request_id', v_request_id);
END;
$$;

-- 8.5 Process role change request
CREATE OR REPLACE FUNCTION public.process_role_request(
    p_request_id UUID,
    p_approved BOOLEAN,
    p_admin_notes TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_request RECORD;
BEGIN
    SELECT * INTO v_request
    FROM public.role_change_requests
    WHERE id = p_request_id AND status = 'pending';
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Request not found');
    END IF;
    
    IF NOT public.user_can_invite(v_request.company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    UPDATE public.role_change_requests
    SET 
        status = CASE WHEN p_approved THEN 'approved' ELSE 'denied' END,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        admin_notes = p_admin_notes
    WHERE id = p_request_id;
    
    IF p_approved THEN
        UPDATE public.company_members
        SET role = v_request.requested_role
        WHERE user_id = v_request.user_id AND company_id = v_request.company_id;
    END IF;
    
    RETURN json_build_object('success', true, 'approved', p_approved);
END;
$$;

-- 8.6 Create company (super user only)
CREATE OR REPLACE FUNCTION public.create_company(
    p_name TEXT,
    p_slug TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('success', false, 'error', 'Only super users can create companies');
    END IF;
    
    IF p_slug !~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$' OR length(p_slug) < 2 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid slug format');
    END IF;
    
    IF EXISTS (SELECT 1 FROM public.companies WHERE slug = p_slug) THEN
        RETURN json_build_object('success', false, 'error', 'Slug already exists');
    END IF;
    
    INSERT INTO public.companies (name, slug)
    VALUES (p_name, p_slug)
    RETURNING id INTO v_company_id;
    
    RETURN json_build_object('success', true, 'company_id', v_company_id);
END;
$$;

-- 8.7 Get all companies (super user only)
CREATE OR REPLACE FUNCTION public.get_all_companies()
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    is_active BOOLEAN,
    member_count BIGINT,
    admin_count BIGINT,
    items_count BIGINT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT 
        c.id, c.name, c.slug, c.is_active,
        (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id),
        (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id AND role = 'admin'),
        (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NULL),
        c.created_at
    FROM public.companies c
    ORDER BY c.name;
END;
$$;

-- 8.8 Get all users (super user only)
CREATE OR REPLACE FUNCTION public.get_all_users()
RETURNS TABLE (
    user_id UUID,
    email TEXT,
    full_name TEXT,
    company_id UUID,
    company_name TEXT,
    role TEXT,
    is_super_user BOOLEAN,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT 
        u.id, u.email,
        COALESCE(p.full_name, ''),
        cm.company_id, c.name,
        cm.role, cm.is_super_user, cm.created_at
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    LEFT JOIN public.company_members cm ON cm.user_id = u.id
    LEFT JOIN public.companies c ON c.id = cm.company_id
    ORDER BY u.email;
END;
$$;

-- 8.9 Get platform metrics (super user only)
CREATE OR REPLACE FUNCTION public.get_platform_metrics()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;
    
    RETURN json_build_object(
        'total_companies', (SELECT COUNT(*) FROM public.companies),
        'active_companies', (SELECT COUNT(*) FROM public.companies WHERE is_active = true),
        'total_users', (SELECT COUNT(*) FROM auth.users),
        'total_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NULL),
        'total_orders', (SELECT COUNT(*) FROM public.orders WHERE deleted_at IS NULL),
        'companies_breakdown', (
            SELECT json_agg(row_to_json(t))
            FROM (
                SELECT 
                    c.name,
                    (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id) as users,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NULL) as items,
                    (SELECT COUNT(*) FROM public.orders WHERE company_id = c.id AND deleted_at IS NULL) as orders
                FROM public.companies c WHERE c.is_active = true
            ) t
        )
    );
END;
$$;

-- 8.10 Soft delete item
CREATE OR REPLACE FUNCTION public.soft_delete_item(p_item_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    SELECT company_id INTO v_company_id
    FROM public.inventory_items
    WHERE id = p_item_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Item not found');
    END IF;
    
    IF NOT public.user_can_delete(v_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = p_item_id;
    
    RETURN json_build_object('success', true, 'message', 'Item moved to trash');
END;
$$;

-- 8.11 Bulk soft delete
CREATE OR REPLACE FUNCTION public.soft_delete_items(p_item_ids UUID[])
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_count INTEGER;
BEGIN
    SELECT company_id INTO v_company_id
    FROM public.inventory_items WHERE id = p_item_ids[1];
    
    IF NOT public.user_can_delete(v_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Create backup snapshot
    PERFORM public.create_snapshot(
        v_company_id, 
        'Pre-Bulk Delete Backup', 
        'Automatic backup before deleting ' || array_length(p_item_ids, 1) || ' items',
        'pre_bulk_delete'
    );
    
    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = ANY(p_item_ids) AND deleted_at IS NULL;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('BULK_DELETE', 'inventory_items', p_item_ids[1], v_company_id, auth.uid(),
        jsonb_build_object('deleted_ids', p_item_ids, 'count', v_count));
    
    RETURN json_build_object('success', true, 'deleted_count', v_count);
END;
$$;

-- 8.12 Restore item from trash
CREATE OR REPLACE FUNCTION public.restore_item(p_item_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    SELECT company_id INTO v_company_id
    FROM public.inventory_items
    WHERE id = p_item_id AND deleted_at IS NOT NULL;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Deleted item not found');
    END IF;
    
    IF NOT public.user_can_delete(v_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    UPDATE public.inventory_items
    SET deleted_at = NULL, deleted_by = NULL
    WHERE id = p_item_id;
    
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('RESTORE', 'inventory_items', p_item_id, v_company_id, auth.uid(),
        jsonb_build_object('restored_at', now()));
    
    RETURN json_build_object('success', true, 'message', 'Item restored');
END;
$$;

-- 8.13 Undo action (super user only)
CREATE OR REPLACE FUNCTION public.undo_action(p_audit_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_audit RECORD;
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('success', false, 'error', 'Only super users can undo actions');
    END IF;
    
    SELECT * INTO v_audit
    FROM public.audit_log
    WHERE id = p_audit_id AND rolled_back_at IS NULL;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Audit entry not found or already rolled back');
    END IF;
    
    CASE v_audit.action
        WHEN 'DELETE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                INSERT INTO public.inventory_items 
                SELECT * FROM jsonb_populate_record(null::public.inventory_items, v_audit.old_values)
                ON CONFLICT (id) DO UPDATE SET
                    deleted_at = NULL, deleted_by = NULL,
                    name = EXCLUDED.name, description = EXCLUDED.description, quantity = EXCLUDED.quantity;
            END IF;
            
        WHEN 'UPDATE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                UPDATE public.inventory_items
                SET 
                    name = (v_audit.old_values->>'name'),
                    description = (v_audit.old_values->>'description'),
                    quantity = (v_audit.old_values->>'quantity')::integer,
                    sku = (v_audit.old_values->>'sku'),
                    updated_at = now()
                WHERE id = v_audit.record_id;
            END IF;
            
        WHEN 'INSERT' THEN
            IF v_audit.table_name = 'inventory_items' THEN
                UPDATE public.inventory_items
                SET deleted_at = now(), deleted_by = auth.uid()
                WHERE id = v_audit.record_id;
            END IF;
            
        ELSE
            RETURN json_build_object('success', false, 'error', 'Cannot undo this action type');
    END CASE;
    
    UPDATE public.audit_log
    SET rolled_back_at = now(), rolled_back_by = auth.uid(), rollback_reason = p_reason
    WHERE id = p_audit_id;
    
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, reason, old_values)
    VALUES ('ROLLBACK', v_audit.table_name, v_audit.record_id, v_audit.company_id, auth.uid(),
        'Undo of action ' || v_audit.id::text,
        jsonb_build_object('original_audit_id', p_audit_id, 'original_action', v_audit.action));
    
    RETURN json_build_object('success', true, 'message', 'Action undone');
END;
$$;

-- 8.14 Create snapshot
CREATE OR REPLACE FUNCTION public.create_snapshot(
    p_company_id UUID,
    p_name TEXT,
    p_description TEXT DEFAULT NULL,
    p_type TEXT DEFAULT 'manual'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_snapshot_id UUID;
    v_items_data JSONB;
    v_items_count INTEGER;
    v_total_qty INTEGER;
BEGIN
    IF NOT (public.is_super_user() OR public.user_can_delete(p_company_id)) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    SELECT jsonb_agg(to_jsonb(i)), COUNT(*), COALESCE(SUM(quantity), 0)
    INTO v_items_data, v_items_count, v_total_qty
    FROM public.inventory_items i
    WHERE company_id = p_company_id AND deleted_at IS NULL;
    
    INSERT INTO public.inventory_snapshots (
        company_id, name, description, snapshot_type,
        items_data, items_count, total_quantity, created_by
    ) VALUES (
        p_company_id, p_name, p_description, p_type,
        COALESCE(v_items_data, '[]'::jsonb), COALESCE(v_items_count, 0), COALESCE(v_total_qty, 0), auth.uid()
    )
    RETURNING id INTO v_snapshot_id;
    
    RETURN json_build_object('success', true, 'snapshot_id', v_snapshot_id, 'items_count', v_items_count, 'total_quantity', v_total_qty);
END;
$$;

-- 8.15 Restore snapshot (super user only)
CREATE OR REPLACE FUNCTION public.restore_snapshot(p_snapshot_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_snapshot RECORD;
    v_item JSONB;
    v_restored_count INTEGER := 0;
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('success', false, 'error', 'Only super users can restore snapshots');
    END IF;
    
    SELECT * INTO v_snapshot FROM public.inventory_snapshots WHERE id = p_snapshot_id;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Snapshot not found');
    END IF;
    
    -- Create backup before restoring
    PERFORM public.create_snapshot(v_snapshot.company_id, 'Pre-Restore Backup', 'Automatic backup before restoring: ' || v_snapshot.name, 'manual');
    
    -- Soft delete current items
    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE company_id = v_snapshot.company_id AND deleted_at IS NULL;
    
    -- Restore from snapshot
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_snapshot.items_data)
    LOOP
        INSERT INTO public.inventory_items (
            id, company_id, name, description, quantity, sku, low_stock_qty, reorder_enabled, metadata, created_at, updated_at
        ) VALUES (
            (v_item->>'id')::uuid, v_snapshot.company_id, v_item->>'name', v_item->>'description',
            (v_item->>'quantity')::integer, v_item->>'sku', (v_item->>'low_stock_qty')::integer,
            (v_item->>'reorder_enabled')::boolean, COALESCE(v_item->'metadata', '{}'::jsonb),
            COALESCE((v_item->>'created_at')::timestamptz, now()), now()
        )
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name, description = EXCLUDED.description, quantity = EXCLUDED.quantity,
            deleted_at = NULL, deleted_by = NULL, updated_at = now();
        
        v_restored_count := v_restored_count + 1;
    END LOOP;
    
    UPDATE public.inventory_snapshots SET restored_at = now(), restored_by = auth.uid() WHERE id = p_snapshot_id;
    
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, reason, new_values)
    VALUES ('ROLLBACK', 'inventory_snapshots', p_snapshot_id, v_snapshot.company_id, auth.uid(),
        COALESCE(p_reason, 'Snapshot restore'),
        jsonb_build_object('snapshot_name', v_snapshot.name, 'items_restored', v_restored_count));
    
    RETURN json_build_object('success', true, 'items_restored', v_restored_count);
END;
$$;

-- 8.16 Get audit log
CREATE OR REPLACE FUNCTION public.get_audit_log(
    p_company_id UUID,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_table_name TEXT DEFAULT NULL,
    p_action TEXT DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    id UUID, action TEXT, table_name TEXT, record_id UUID,
    user_email TEXT, user_role TEXT, old_values JSONB, new_values JSONB,
    changed_fields TEXT[], created_at TIMESTAMPTZ, is_rolled_back BOOLEAN, rolled_back_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (public.is_super_user() OR public.user_can_invite(p_company_id)) THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT 
        a.id, a.action, a.table_name, a.record_id,
        a.user_email, a.user_role, a.old_values, a.new_values,
        a.changed_fields, a.created_at, (a.rolled_back_at IS NOT NULL), a.rolled_back_at
    FROM public.audit_log a
    WHERE a.company_id = p_company_id
    AND (p_table_name IS NULL OR a.table_name = p_table_name)
    AND (p_action IS NULL OR a.action = p_action)
    AND (p_user_id IS NULL OR a.user_id = p_user_id)
    AND (p_start_date IS NULL OR a.created_at >= p_start_date)
    AND (p_end_date IS NULL OR a.created_at <= p_end_date)
    ORDER BY a.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- 8.17 Get deleted items (trash)
CREATE OR REPLACE FUNCTION public.get_deleted_items(p_company_id UUID)
RETURNS TABLE (id UUID, name TEXT, description TEXT, quantity INTEGER, deleted_at TIMESTAMPTZ, deleted_by_email TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (public.is_super_user() OR public.user_can_delete(p_company_id)) THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT i.id, i.name, i.description, i.quantity, i.deleted_at, u.email
    FROM public.inventory_items i
    LEFT JOIN auth.users u ON u.id = i.deleted_by
    WHERE i.company_id = p_company_id AND i.deleted_at IS NOT NULL
    ORDER BY i.deleted_at DESC;
END;
$$;

-- 8.18 Get snapshots
CREATE OR REPLACE FUNCTION public.get_snapshots(p_company_id UUID)
RETURNS TABLE (
    id UUID, name TEXT, description TEXT, snapshot_type TEXT,
    items_count INTEGER, total_quantity INTEGER, created_at TIMESTAMPTZ,
    created_by_email TEXT, was_restored BOOLEAN, restored_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (public.is_super_user() OR public.user_can_delete(p_company_id)) THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT s.id, s.name, s.description, s.snapshot_type, s.items_count, s.total_quantity,
        s.created_at, u.email, (s.restored_at IS NOT NULL), s.restored_at
    FROM public.inventory_snapshots s
    LEFT JOIN auth.users u ON u.id = s.created_by
    WHERE s.company_id = p_company_id
    ORDER BY s.created_at DESC;
END;
$$;

-- 8.19 Get action metrics (super user only)
CREATE OR REPLACE FUNCTION public.get_action_metrics(p_company_id UUID DEFAULT NULL, p_days INTEGER DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;
    
    RETURN json_build_object(
        'period_days', p_days,
        'total_deletes', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'delete'),
        'total_updates', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'update'),
        'total_restores', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'restore'),
        'quantity_removed', (SELECT COALESCE(SUM(quantity_removed), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days),
        'quantity_added', (SELECT COALESCE(SUM(quantity_added), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days)
    );
END;
$$;

-- 8.20 Daily snapshots function (for scheduled job)
CREATE OR REPLACE FUNCTION public.create_daily_snapshots()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company RECORD;
BEGIN
    FOR v_company IN SELECT id, name FROM public.companies WHERE is_active = true
    LOOP
        PERFORM public.create_snapshot(v_company.id, 'Daily Backup ' || to_char(CURRENT_DATE, 'YYYY-MM-DD'), 'Automatic daily backup', 'auto_daily');
    END LOOP;
    
    -- Clean old auto snapshots (keep 30 days)
    DELETE FROM public.inventory_snapshots
    WHERE snapshot_type IN ('auto_daily', 'auto_weekly')
    AND created_at < now() - interval '30 days'
    AND restored_at IS NULL;
END;
$$;

-- ============================================================================
-- SECTION 9: DATA MIGRATION
-- ============================================================================

DO $$
DECLARE
    v_company_id UUID;
    v_first_admin_id UUID;
BEGIN
    SELECT id INTO v_company_id FROM public.companies WHERE slug = 'oakley-services';
    
    IF v_company_id IS NULL THEN
        INSERT INTO public.companies (name, slug, settings)
        VALUES ('Oakley Services', 'oakley-services', '{"migrated_from_legacy": true}'::jsonb)
        RETURNING id INTO v_company_id;
        RAISE NOTICE 'Created company: Oakley Services (ID: %)', v_company_id;
    END IF;
    
    SELECT user_id INTO v_first_admin_id
    FROM public.authorized_users WHERE role = 'admin' ORDER BY created_at ASC LIMIT 1;
    
    INSERT INTO public.company_members (company_id, user_id, role, is_super_user, assigned_admin_id)
    SELECT v_company_id, au.user_id,
        CASE WHEN au.user_id = v_first_admin_id THEN 'admin' WHEN au.role = 'admin' THEN 'admin' ELSE COALESCE(au.role, 'member') END,
        au.user_id = v_first_admin_id,
        v_first_admin_id
    FROM public.authorized_users au
    ON CONFLICT (company_id, user_id) DO UPDATE SET is_super_user = EXCLUDED.is_super_user;
    
    RAISE NOTICE 'Migrated authorized_users';
    
    INSERT INTO public.inventory_items (id, company_id, name, description, quantity, low_stock_qty, reorder_enabled, created_at, updated_at)
    SELECT i.id, v_company_id, i.name, COALESCE(i.description, ''), COALESCE(i.qty, 0),
        i.low_stock_qty, COALESCE(i.reorder_enabled, false), COALESCE(i.created_at, now()), COALESCE(i.updated_at, now())
    FROM public.items i
    ON CONFLICT (id) DO NOTHING;
    
    RAISE NOTICE 'Migrated items to inventory_items';
    
    UPDATE public.orders SET company_id = v_company_id WHERE company_id IS NULL;
    UPDATE public.order_recipients SET company_id = v_company_id WHERE company_id IS NULL;
    
    RAISE NOTICE 'Migration complete';
END $$;

-- ============================================================================
-- SECTION 10: GRANT PERMISSIONS
-- ============================================================================

-- Helper functions
GRANT EXECUTE ON FUNCTION public.is_super_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_company_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_role(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_delete(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_write(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_invite(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_permissions(UUID) TO authenticated;

-- RPC functions
GRANT EXECUTE ON FUNCTION public.accept_invitation(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_companies() TO authenticated;
GRANT EXECUTE ON FUNCTION public.invite_user(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_role_change(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_role_request(UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_company(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_all_companies() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_all_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_platform_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_item(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_items(UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_item(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.undo_action(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_snapshot(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_snapshot(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_audit_log(UUID, INTEGER, INTEGER, TEXT, TEXT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_deleted_items(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_snapshots(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_action_metrics(UUID, INTEGER) TO authenticated;

-- Table permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.companies TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.company_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invitations TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.role_change_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_locations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_categories TO authenticated;
GRANT SELECT, INSERT ON public.inventory_transactions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.orders TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.order_recipients TO authenticated;
GRANT SELECT ON public.audit_log TO authenticated;
GRANT SELECT, INSERT ON public.inventory_snapshots TO authenticated;
GRANT SELECT ON public.action_metrics TO authenticated;
GRANT SELECT, UPDATE ON public.role_configurations TO authenticated;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

COMMIT;

-- ============================================================================
-- POST-MIGRATION: RUN MANUALLY AFTER VERIFICATION
-- ============================================================================
-- DROP TABLE IF EXISTS public.items;
-- DROP TABLE IF EXISTS public.authorized_users;
```

---

## Frontend Implementation

### 7.1 Global State Updates

```javascript
const SB = { 
    // Existing properties...
    client: null,
    session: null,
    user: null,
    ready: false,
    
    // NEW: Company context
    currentCompanyId: null,
    currentCompanyName: null,
    companies: [],
    
    // NEW: Permissions
    permissions: {
        role: null,
        is_super_user: false,
        can_read: false,
        can_create: false,
        can_update: false,
        can_delete: false,
        can_invite: false,
        can_manage_users: false,
        can_view_all_companies: false,
        can_view_metrics: false,
        can_restore_snapshots: false,
        can_undo_actions: false,
        assigned_admin_id: null,
        assigned_admin_email: null
    }
};
```

### 7.2 Login Modal (Remove Signup)

```html
<div id="authModal" class="modal" aria-hidden="true">
  <div class="modal-content auth-modal">
    <h2>Sign In</h2>
    <form id="authForm" onsubmit="return handleLogin(event)">
      <div class="form-group">
        <label for="authEmail">Email</label>
        <input type="email" id="authEmail" required autocomplete="email" />
      </div>
      <div class="form-group">
        <label for="authPassword">Password</label>
        <input type="password" id="authPassword" required autocomplete="current-password" />
      </div>
      <button type="submit" class="btn primary">Sign In</button>
    </form>
    <div class="auth-links">
      <a href="#" onclick="showForgotPassword(); return false;">Forgot Password?</a>
    </div>
    <p class="auth-note">Access is by invitation only.</p>
  </div>
</div>
```

### 7.3 Load Companies and Permissions

```javascript
async function sbLoadCompanies() {
    if (!SB.ready || !SB.session) return [];
    
    try {
        const { data, error } = await SB.client.rpc('get_my_companies');
        if (error) throw error;
        
        SB.companies = data || [];
        
        if (SB.companies.length === 0) {
            showNoCompanyMessage();
            return [];
        }
        
        // Set current company from localStorage or use first
        const savedId = localStorage.getItem('inv.currentCompanyId');
        const saved = SB.companies.find(c => c.company_id === savedId);
        const active = saved || SB.companies[0];
        
        SB.currentCompanyId = active.company_id;
        SB.currentCompanyName = active.company_name;
        localStorage.setItem('inv.currentCompanyId', SB.currentCompanyId);
        
        await sbLoadPermissions();
        return SB.companies;
    } catch (e) {
        console.error('Failed to load companies:', e);
        return [];
    }
}

async function sbLoadPermissions() {
    if (!SB.currentCompanyId) return;
    
    try {
        const { data, error } = await SB.client.rpc('get_my_permissions', { 
            p_company_id: SB.currentCompanyId 
        });
        if (error) throw error;
        SB.permissions = data || SB.permissions;
        
        applyPermissionVisibility();
        updateProfileDropdown();
    } catch (e) {
        console.error('Failed to load permissions:', e);
    }
}
```

### 7.4 Permission-Based UI Visibility

```javascript
function canDelete() { return SB.permissions.can_delete === true; }
function canCreate() { return SB.permissions.can_create === true; }
function canUpdate() { return SB.permissions.can_update === true; }
function canInvite() { return SB.permissions.can_invite === true; }
function isSuperUser() { return SB.permissions.is_super_user === true; }

function applyPermissionVisibility() {
    // Delete buttons
    document.querySelectorAll('.delete-btn, .row-delete-btn, [data-action="delete"]').forEach(el => {
        el.style.display = canDelete() ? '' : 'none';
    });
    
    // Add buttons
    document.querySelectorAll('.add-btn, [data-action="add"]').forEach(el => {
        el.style.display = canCreate() ? '' : 'none';
    });
    
    // Edit buttons
    document.querySelectorAll('.edit-btn, [data-action="edit"]').forEach(el => {
        el.style.display = canUpdate() ? '' : 'none';
    });
    
    // Invite button
    document.querySelectorAll('.invite-btn, [data-action="invite"]').forEach(el => {
        el.style.display = canInvite() ? '' : 'none';
    });
    
    // Super user only
    document.querySelectorAll('[data-super-only]').forEach(el => {
        el.style.display = isSuperUser() ? '' : 'none';
    });
    
    // Company switcher
    const switcher = document.getElementById('companySwitcher');
    if (switcher) switcher.style.display = isSuperUser() ? '' : 'none';
}
```

### 7.5 Invitation Flow

```javascript
async function checkPendingInvitation() {
    const urlParams = new URLSearchParams(window.location.search);
    const inviteToken = urlParams.get('invite');
    
    if (inviteToken) {
        localStorage.setItem('inv.pendingInvite', inviteToken);
        window.history.replaceState({}, '', window.location.pathname);
    }
    
    const pending = localStorage.getItem('inv.pendingInvite');
    if (pending && SB.session) {
        try {
            const { data, error } = await SB.client.rpc('accept_invitation', { 
                invitation_token: pending 
            });
            
            if (data?.success) {
                localStorage.removeItem('inv.pendingInvite');
                toast(`Welcome! You've joined as ${data.role}.`);
                await sbLoadCompanies();
            } else {
                toast(data?.error || 'Failed to accept invitation', 'error');
            }
        } catch (e) {
            toast('Invitation error', 'error');
        }
    }
}
```

### 7.6 Query Updates

```javascript
// BEFORE
await SB.client.from('items').select('*');

// AFTER
await SB.client
    .from('inventory_items')
    .select('*')
    .eq('company_id', SB.currentCompanyId)
    .is('deleted_at', null);

// BEFORE (delete)
await SB.client.from('items').delete().eq('id', id);

// AFTER (soft delete)
const { data } = await SB.client.rpc('soft_delete_item', { p_item_id: id });
if (data?.success) toast('Item moved to trash');
```

### 7.7 Find and Replace

| Find | Replace |
|------|---------|
| `.from('items')` | `.from('inventory_items')` |
| `qty:` | `quantity:` |
| `qty,` | `quantity,` |
| `.qty` | `.quantity` |

---

## Testing Checklist

### Authentication
- [ ] Login shows ONLY email + password
- [ ] No signup option visible
- [ ] Forgot password works
- [ ] Invalid credentials show error

### Permissions

| Test | Super User | Admin | Member | Viewer |
|------|------------|-------|--------|--------|
| See inventory | ✅ | ✅ | ✅ | ✅ |
| Add button visible | ✅ | ✅ | ✅ | ❌ |
| Delete button visible | ✅ | ✅ | ❌ | ❌ |
| Invite button visible | ✅ | ✅ | ❌ | ❌ |
| Admin dashboard | ✅ | ❌ | ❌ | ❌ |
| Company switcher | ✅ | ❌ | ❌ | ❌ |

### Data Protection
- [ ] Delete moves to trash (not permanent)
- [ ] Trash shows deleted items
- [ ] Restore from trash works
- [ ] Snapshots can be created
- [ ] Super user can restore snapshots
- [ ] Audit log shows all changes
- [ ] Super user can undo actions

### Invitations
- [ ] Admin can invite users
- [ ] Invite link works
- [ ] New user joins correct company
- [ ] Correct role assigned

---

## Rollout Plan

1. **Backup** production database
2. **Run migration**: `supabase db push`
3. **Verify migration**:
   ```sql
   SELECT * FROM companies WHERE slug = 'oakley-services';
   SELECT * FROM company_members WHERE is_super_user = true;
   SELECT COUNT(*) FROM inventory_items;
   ```
4. **Deploy frontend** changes
5. **Test** all role scenarios
6. **Drop old tables** after verification:
   ```sql
   DROP TABLE IF EXISTS public.items;
   DROP TABLE IF EXISTS public.authorized_users;
   ```
