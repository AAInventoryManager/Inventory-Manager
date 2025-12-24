# Inventory Manager: Phase 1B Complete Specification
## Snapshots, Metrics, Security Validation & Role Engine

**Version:** 1.0  
**Date:** December 2024  
**Production URL:** `https://inventory.modulus-software.com`  
**Supabase Project:** Inventory Manager  
**Prerequisite:** Phase 1 core implementation complete

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Phase 1B Scope](#phase-1b-scope)
3. [Part 1: Snapshots UI](#part-1-snapshots-ui)
4. [Part 2: Action Metrics Dashboard](#part-2-action-metrics-dashboard)
5. [Part 3: Security Testing Checklist](#part-3-security-testing-checklist)
6. [Part 4: Role Engine](#part-4-role-engine)
7. [Implementation Order](#implementation-order)
8. [Consolidated Testing Checklist](#consolidated-testing-checklist)

---

## Executive Summary

Phase 1B completes the multi-tenant SaaS transformation by adding:

| Component | Purpose | Business Value |
|-----------|---------|----------------|
| **Snapshots UI** | Point-in-time backup & restore | Data recovery selling point for B2B |
| **Metrics Dashboard** | Activity visualization | Operational insights, engagement tracking |
| **Security Testing** | RLS validation & audit verification | Confidence for production launch |
| **Role Engine** | Centralized permission management | Scalable, UI-managed access control |

### Phase 1 → 1B Relationship

```
Phase 1 (COMPLETE)                    Phase 1B (THIS DOCUMENT)
─────────────────────                 ────────────────────────
✅ Multi-tenant schema                → Snapshots UI
✅ Company scoping + RLS              → Metrics Dashboard  
✅ Soft deletes + trash               → Security Testing
✅ Invitation flow                    → Role Engine
✅ Audit log viewer
✅ Permission gating (hardcoded)
```

---

## Phase 1B Scope

### In Scope

| Item | Description | Effort |
|------|-------------|--------|
| Snapshots UI | Create/view/restore from `inventory_snapshots` table | Medium |
| Metrics Dashboard | Per-company + platform-wide activity metrics | Medium |
| Security Testing | RLS negative tests, audit verification, rollout checklist | Low |
| Role Engine | Centralized permissions, Super User management UI | Medium |

### Out of Scope (Phase 2+)

- Stock Adjustment feature
- Receive Inventory feature
- Menu restructure
- Locations/Warehouses
- Vendors/Suppliers
- Custom roles per company

---

# Part 1: Snapshots UI

## Overview

Snapshots provide point-in-time backups of inventory data that can be restored if needed. This is a key B2B selling point — businesses need protection against accidental bulk deletes or bad imports.

### User Stories

| Role | Story |
|------|-------|
| Admin | "I want to create a snapshot before a major inventory update so I can rollback if needed" |
| Admin | "I want to see a list of available snapshots with timestamps and who created them" |
| Super User | "I want to restore a snapshot to recover from accidental data loss" |
| Viewer | Cannot access snapshots |

### Snapshot Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SNAPSHOT LIFECYCLE                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐      ┌──────────────┐      ┌──────────────┐              │
│  │  CREATE  │      │    STORE     │      │   RESTORE    │              │
│  │ Snapshot │ ───► │  in Table    │ ───► │  (Optional)  │              │
│  └──────────┘      └──────────────┘      └──────────────┘              │
│       │                   │                     │                       │
│       ▼                   ▼                     ▼                       │
│  Captures:           Contains:             Restores:                    │
│  • All items         • JSONB data          • Replaces current items    │
│  • Quantities        • Timestamp           • Logs restore action       │
│  • Metadata          • Created by          • Creates new audit entry   │
│                      • Item count                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Database Schema

### Existing Table: `inventory_snapshots`

```sql
-- This table should already exist from Phase 1 migration
-- Verify it matches this structure:

CREATE TABLE IF NOT EXISTS inventory_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name TEXT,                                    -- Optional user-provided name
    description TEXT,                             -- Optional description
    snapshot_data JSONB NOT NULL,                 -- Array of inventory items
    item_count INTEGER NOT NULL,                  -- Cached count for display
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    
    -- Metadata for display
    total_quantity INTEGER,                       -- Sum of all item quantities
    total_value DECIMAL(12,2)                     -- Sum of all item values (if tracked)
);

-- RLS Policies
ALTER TABLE inventory_snapshots ENABLE ROW LEVEL SECURITY;

-- Users can only see snapshots for their company
CREATE POLICY "snapshots_select_company" ON inventory_snapshots
    FOR SELECT TO authenticated
    USING (
        company_id IN (
            SELECT company_id FROM company_members 
            WHERE user_id = auth.uid() AND deleted_at IS NULL
        )
    );

-- Only admins+ can create snapshots
CREATE POLICY "snapshots_insert_admin" ON inventory_snapshots
    FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM company_members
            WHERE company_id = inventory_snapshots.company_id
              AND user_id = auth.uid()
              AND role IN ('super_user', 'admin')
              AND deleted_at IS NULL
        )
    );

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_snapshots_company_id ON inventory_snapshots(company_id);
CREATE INDEX IF NOT EXISTS idx_snapshots_created_at ON inventory_snapshots(created_at DESC);
```

## RPC Functions

### Create Snapshot

```sql
CREATE OR REPLACE FUNCTION create_inventory_snapshot(
    p_company_id UUID,
    p_name TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
) RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_user_role TEXT;
    v_snapshot_id UUID;
    v_snapshot_data JSONB;
    v_item_count INTEGER;
    v_total_quantity INTEGER;
BEGIN
    v_user_id := auth.uid();
    
    -- Verify user is admin+ in this company
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = p_company_id
      AND user_id = v_user_id
      AND deleted_at IS NULL;
    
    IF v_user_role NOT IN ('super_user', 'admin') THEN
        RAISE EXCEPTION 'Permission denied: admin role required to create snapshots';
    END IF;
    
    -- Capture current inventory state
    SELECT 
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', id,
                'name', name,
                'sku', sku,
                'quantity', quantity,
                'description', description,
                'category', category,
                'location', location,
                'unit_cost', unit_cost,
                'reorder_point', reorder_point,
                'reorder_quantity', reorder_quantity,
                'created_at', created_at,
                'updated_at', updated_at
            )
        ), '[]'::jsonb),
        COUNT(*),
        COALESCE(SUM(quantity), 0)
    INTO v_snapshot_data, v_item_count, v_total_quantity
    FROM inventory_items
    WHERE company_id = p_company_id
      AND deleted_at IS NULL;
    
    -- Create snapshot record
    INSERT INTO inventory_snapshots (
        company_id,
        name,
        description,
        snapshot_data,
        item_count,
        total_quantity,
        created_by
    ) VALUES (
        p_company_id,
        COALESCE(p_name, 'Snapshot ' || to_char(now(), 'YYYY-MM-DD HH24:MI')),
        p_description,
        v_snapshot_data,
        v_item_count,
        v_total_quantity,
        v_user_id
    )
    RETURNING id INTO v_snapshot_id;
    
    -- Log to audit
    INSERT INTO audit_log (
        company_id,
        user_id,
        action,
        table_name,
        record_id,
        new_data
    ) VALUES (
        p_company_id,
        v_user_id,
        'snapshot_created',
        'inventory_snapshots',
        v_snapshot_id,
        jsonb_build_object(
            'name', p_name,
            'item_count', v_item_count,
            'total_quantity', v_total_quantity
        )
    );
    
    RETURN v_snapshot_id;
END;
$$;
```

### Get Snapshots List

```sql
CREATE OR REPLACE FUNCTION get_inventory_snapshots(
    p_company_id UUID,
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    item_count INTEGER,
    total_quantity INTEGER,
    created_by UUID,
    created_by_email TEXT,
    created_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
    -- Verify user has access to this company
    IF NOT EXISTS (
        SELECT 1 FROM company_members
        WHERE company_id = p_company_id
          AND user_id = auth.uid()
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    RETURN QUERY
    SELECT 
        s.id,
        s.name,
        s.description,
        s.item_count,
        s.total_quantity,
        s.created_by,
        p.email AS created_by_email,
        s.created_at
    FROM inventory_snapshots s
    LEFT JOIN profiles p ON p.id = s.created_by
    WHERE s.company_id = p_company_id
    ORDER BY s.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;
```

### Get Snapshot Detail (for preview before restore)

```sql
CREATE OR REPLACE FUNCTION get_snapshot_detail(
    p_snapshot_id UUID
) RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    item_count INTEGER,
    total_quantity INTEGER,
    snapshot_data JSONB,
    created_by_email TEXT,
    created_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    -- Get company_id from snapshot
    SELECT company_id INTO v_company_id
    FROM inventory_snapshots
    WHERE id = p_snapshot_id;
    
    -- Verify user has access
    IF NOT EXISTS (
        SELECT 1 FROM company_members
        WHERE company_id = v_company_id
          AND user_id = auth.uid()
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    RETURN QUERY
    SELECT 
        s.id,
        s.name,
        s.description,
        s.item_count,
        s.total_quantity,
        s.snapshot_data,
        p.email AS created_by_email,
        s.created_at
    FROM inventory_snapshots s
    LEFT JOIN profiles p ON p.id = s.created_by
    WHERE s.id = p_snapshot_id;
END;
$$;
```

### Restore Snapshot

```sql
CREATE OR REPLACE FUNCTION restore_inventory_snapshot(
    p_snapshot_id UUID,
    p_restore_mode TEXT DEFAULT 'replace'  -- 'replace' or 'merge'
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_company_id UUID;
    v_user_role TEXT;
    v_snapshot_data JSONB;
    v_item JSONB;
    v_items_restored INTEGER := 0;
    v_items_skipped INTEGER := 0;
    v_pre_restore_snapshot_id UUID;
BEGIN
    v_user_id := auth.uid();
    
    -- Get snapshot details
    SELECT company_id, snapshot_data 
    INTO v_company_id, v_snapshot_data
    FROM inventory_snapshots
    WHERE id = p_snapshot_id;
    
    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'Snapshot not found';
    END IF;
    
    -- Verify user is super_user (only SU can restore)
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = v_company_id
      AND user_id = v_user_id
      AND deleted_at IS NULL;
    
    IF v_user_role != 'super_user' THEN
        RAISE EXCEPTION 'Permission denied: only Super User can restore snapshots';
    END IF;
    
    -- Auto-create a pre-restore snapshot for safety
    SELECT create_inventory_snapshot(
        v_company_id,
        'Pre-restore backup ' || to_char(now(), 'YYYY-MM-DD HH24:MI'),
        'Automatic backup before restoring snapshot: ' || p_snapshot_id::text
    ) INTO v_pre_restore_snapshot_id;
    
    IF p_restore_mode = 'replace' THEN
        -- Soft delete all current items
        UPDATE inventory_items
        SET deleted_at = now(),
            deleted_by = v_user_id
        WHERE company_id = v_company_id
          AND deleted_at IS NULL;
        
        -- Insert items from snapshot
        FOR v_item IN SELECT * FROM jsonb_array_elements(v_snapshot_data)
        LOOP
            INSERT INTO inventory_items (
                company_id,
                name,
                sku,
                quantity,
                description,
                category,
                location,
                unit_cost,
                reorder_point,
                reorder_quantity,
                created_by
            ) VALUES (
                v_company_id,
                v_item->>'name',
                v_item->>'sku',
                (v_item->>'quantity')::integer,
                v_item->>'description',
                v_item->>'category',
                v_item->>'location',
                (v_item->>'unit_cost')::decimal,
                (v_item->>'reorder_point')::integer,
                (v_item->>'reorder_quantity')::integer,
                v_user_id
            );
            v_items_restored := v_items_restored + 1;
        END LOOP;
        
    ELSIF p_restore_mode = 'merge' THEN
        -- Merge mode: only restore items that don't exist (by SKU)
        FOR v_item IN SELECT * FROM jsonb_array_elements(v_snapshot_data)
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM inventory_items
                WHERE company_id = v_company_id
                  AND sku = v_item->>'sku'
                  AND deleted_at IS NULL
            ) THEN
                INSERT INTO inventory_items (
                    company_id,
                    name,
                    sku,
                    quantity,
                    description,
                    category,
                    location,
                    unit_cost,
                    reorder_point,
                    reorder_quantity,
                    created_by
                ) VALUES (
                    v_company_id,
                    v_item->>'name',
                    v_item->>'sku',
                    (v_item->>'quantity')::integer,
                    v_item->>'description',
                    v_item->>'category',
                    v_item->>'location',
                    (v_item->>'unit_cost')::decimal,
                    (v_item->>'reorder_point')::integer,
                    (v_item->>'reorder_quantity')::integer,
                    v_user_id
                );
                v_items_restored := v_items_restored + 1;
            ELSE
                v_items_skipped := v_items_skipped + 1;
            END IF;
        END LOOP;
    END IF;
    
    -- Log the restore action
    INSERT INTO audit_log (
        company_id,
        user_id,
        action,
        table_name,
        record_id,
        new_data
    ) VALUES (
        v_company_id,
        v_user_id,
        'snapshot_restored',
        'inventory_snapshots',
        p_snapshot_id,
        jsonb_build_object(
            'restore_mode', p_restore_mode,
            'items_restored', v_items_restored,
            'items_skipped', v_items_skipped,
            'pre_restore_snapshot_id', v_pre_restore_snapshot_id
        )
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'items_restored', v_items_restored,
        'items_skipped', v_items_skipped,
        'pre_restore_snapshot_id', v_pre_restore_snapshot_id,
        'restore_mode', p_restore_mode
    );
END;
$$;
```

### Delete Snapshot

```sql
CREATE OR REPLACE FUNCTION delete_inventory_snapshot(
    p_snapshot_id UUID
) RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_company_id UUID;
    v_user_role TEXT;
BEGIN
    v_user_id := auth.uid();
    
    -- Get company_id from snapshot
    SELECT company_id INTO v_company_id
    FROM inventory_snapshots
    WHERE id = p_snapshot_id;
    
    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'Snapshot not found';
    END IF;
    
    -- Verify user is admin+
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = v_company_id
      AND user_id = v_user_id
      AND deleted_at IS NULL;
    
    IF v_user_role NOT IN ('super_user', 'admin') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Delete the snapshot
    DELETE FROM inventory_snapshots WHERE id = p_snapshot_id;
    
    -- Log deletion
    INSERT INTO audit_log (
        company_id,
        user_id,
        action,
        table_name,
        record_id
    ) VALUES (
        v_company_id,
        v_user_id,
        'snapshot_deleted',
        'inventory_snapshots',
        p_snapshot_id
    );
    
    RETURN true;
END;
$$;
```

## Frontend Implementation

### Snapshots Page (`/pages/snapshots.html`)

```html
<div id="snapshots-page" class="page">
    <header class="page-header">
        <div class="header-content">
            <h1>Inventory Snapshots</h1>
            <p>Point-in-time backups of your inventory data</p>
        </div>
        <div class="header-actions" id="snapshot-actions">
            <!-- Create button inserted by JS if user has permission -->
        </div>
    </header>
    
    <div class="snapshots-list" id="snapshots-list">
        <!-- Populated by JavaScript -->
    </div>
    
    <!-- Create Snapshot Modal -->
    <div id="create-snapshot-modal" class="modal" hidden>
        <div class="modal-content">
            <h2>Create Snapshot</h2>
            <form id="create-snapshot-form">
                <div class="form-group">
                    <label for="snapshot-name">Name (optional)</label>
                    <input type="text" id="snapshot-name" 
                        placeholder="e.g., Before Q4 inventory update">
                </div>
                <div class="form-group">
                    <label for="snapshot-description">Description (optional)</label>
                    <textarea id="snapshot-description" rows="3"
                        placeholder="Why are you creating this snapshot?"></textarea>
                </div>
                <div class="form-actions">
                    <button type="button" class="btn-secondary" data-close-modal>Cancel</button>
                    <button type="submit" class="btn-primary">Create Snapshot</button>
                </div>
            </form>
        </div>
    </div>
    
    <!-- Restore Confirmation Modal -->
    <div id="restore-snapshot-modal" class="modal" hidden>
        <div class="modal-content modal-warning">
            <h2>⚠️ Restore Snapshot</h2>
            <div id="restore-snapshot-details">
                <!-- Populated by JS -->
            </div>
            <div class="restore-options">
                <label class="radio-option">
                    <input type="radio" name="restore-mode" value="replace" checked>
                    <span><strong>Replace</strong> — Delete all current items and restore from snapshot</span>
                </label>
                <label class="radio-option">
                    <input type="radio" name="restore-mode" value="merge">
                    <span><strong>Merge</strong> — Only add items that don't exist (by SKU)</span>
                </label>
            </div>
            <p class="warning-text">
                A backup snapshot will be created automatically before restore.
            </p>
            <div class="form-actions">
                <button type="button" class="btn-secondary" data-close-modal>Cancel</button>
                <button type="button" class="btn-danger" id="confirm-restore-btn">
                    Restore Snapshot
                </button>
            </div>
        </div>
    </div>
    
    <!-- Preview Modal -->
    <div id="preview-snapshot-modal" class="modal" hidden>
        <div class="modal-content modal-large">
            <h2>Snapshot Preview</h2>
            <div id="snapshot-preview-content">
                <!-- Populated by JS -->
            </div>
            <div class="form-actions">
                <button type="button" class="btn-secondary" data-close-modal>Close</button>
            </div>
        </div>
    </div>
</div>
```

### Snapshots JavaScript (`/js/snapshots.js`)

```javascript
import { SB } from '../services/supabase.js';
import { getCurrentCompanyId, getUserRole } from '../services/company.js';
import { showToast, formatDate, escapeHtml } from '../utils/helpers.js';

class SnapshotsManager {
    constructor() {
        this.companyId = null;
        this.userRole = null;
        this.snapshots = [];
        this.selectedSnapshotId = null;
    }

    async init() {
        this.companyId = getCurrentCompanyId();
        this.userRole = getUserRole();
        
        this.renderActionButtons();
        await this.loadSnapshots();
        this.attachEventListeners();
    }

    renderActionButtons() {
        const container = document.getElementById('snapshot-actions');
        
        // Only admin+ can create snapshots
        if (['super_user', 'admin'].includes(this.userRole)) {
            container.innerHTML = `
                <button id="btn-create-snapshot" class="btn-primary">
                    + Create Snapshot
                </button>
            `;
        }
    }

    async loadSnapshots() {
        const { data, error } = await SB.client
            .rpc('get_inventory_snapshots', {
                p_company_id: this.companyId,
                p_limit: 50
            });
        
        if (error) {
            console.error('Failed to load snapshots:', error);
            showToast('Failed to load snapshots', 'error');
            return;
        }
        
        this.snapshots = data || [];
        this.renderSnapshotsList();
    }

    renderSnapshotsList() {
        const container = document.getElementById('snapshots-list');
        
        if (this.snapshots.length === 0) {
            container.innerHTML = `
                <div class="empty-state">
                    <h3>No Snapshots Yet</h3>
                    <p>Create your first snapshot to have a backup of your inventory data.</p>
                </div>
            `;
            return;
        }
        
        const canRestore = this.userRole === 'super_user';
        const canDelete = ['super_user', 'admin'].includes(this.userRole);
        
        container.innerHTML = this.snapshots.map(snapshot => `
            <div class="snapshot-card" data-id="${snapshot.id}">
                <div class="snapshot-header">
                    <h3>${escapeHtml(snapshot.name)}</h3>
                    <span class="snapshot-date">${formatDate(snapshot.created_at)}</span>
                </div>
                ${snapshot.description ? `
                    <p class="snapshot-description">${escapeHtml(snapshot.description)}</p>
                ` : ''}
                <div class="snapshot-meta">
                    <span class="meta-item">
                        <strong>${snapshot.item_count}</strong> items
                    </span>
                    <span class="meta-item">
                        <strong>${snapshot.total_quantity?.toLocaleString() || 0}</strong> total qty
                    </span>
                    <span class="meta-item">
                        Created by ${escapeHtml(snapshot.created_by_email || 'Unknown')}
                    </span>
                </div>
                <div class="snapshot-actions">
                    <button class="btn-secondary btn-sm btn-preview" data-id="${snapshot.id}">
                        Preview
                    </button>
                    ${canRestore ? `
                        <button class="btn-primary btn-sm btn-restore" data-id="${snapshot.id}">
                            Restore
                        </button>
                    ` : ''}
                    ${canDelete ? `
                        <button class="btn-danger btn-sm btn-delete" data-id="${snapshot.id}">
                            Delete
                        </button>
                    ` : ''}
                </div>
            </div>
        `).join('');
    }

    attachEventListeners() {
        // Create snapshot button
        document.getElementById('btn-create-snapshot')?.addEventListener('click', () => {
            document.getElementById('create-snapshot-modal').hidden = false;
        });
        
        // Create snapshot form
        document.getElementById('create-snapshot-form')?.addEventListener('submit', (e) => {
            e.preventDefault();
            this.createSnapshot();
        });
        
        // Snapshot action buttons (delegated)
        document.getElementById('snapshots-list').addEventListener('click', (e) => {
            const btn = e.target.closest('button');
            if (!btn) return;
            
            const snapshotId = btn.dataset.id;
            
            if (btn.classList.contains('btn-preview')) {
                this.previewSnapshot(snapshotId);
            } else if (btn.classList.contains('btn-restore')) {
                this.showRestoreModal(snapshotId);
            } else if (btn.classList.contains('btn-delete')) {
                this.deleteSnapshot(snapshotId);
            }
        });
        
        // Confirm restore button
        document.getElementById('confirm-restore-btn')?.addEventListener('click', () => {
            this.restoreSnapshot();
        });
        
        // Close modal buttons
        document.querySelectorAll('[data-close-modal]').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.target.closest('.modal').hidden = true;
            });
        });
    }

    async createSnapshot() {
        const name = document.getElementById('snapshot-name').value.trim();
        const description = document.getElementById('snapshot-description').value.trim();
        
        const { data, error } = await SB.client
            .rpc('create_inventory_snapshot', {
                p_company_id: this.companyId,
                p_name: name || null,
                p_description: description || null
            });
        
        if (error) {
            console.error('Failed to create snapshot:', error);
            showToast('Failed to create snapshot: ' + error.message, 'error');
            return;
        }
        
        showToast('Snapshot created successfully', 'success');
        document.getElementById('create-snapshot-modal').hidden = true;
        document.getElementById('create-snapshot-form').reset();
        await this.loadSnapshots();
    }

    async previewSnapshot(snapshotId) {
        const { data, error } = await SB.client
            .rpc('get_snapshot_detail', { p_snapshot_id: snapshotId });
        
        if (error || !data || data.length === 0) {
            showToast('Failed to load snapshot details', 'error');
            return;
        }
        
        const snapshot = data[0];
        const items = snapshot.snapshot_data || [];
        
        const content = document.getElementById('snapshot-preview-content');
        content.innerHTML = `
            <div class="preview-header">
                <h3>${escapeHtml(snapshot.name)}</h3>
                <p>${snapshot.item_count} items • Created ${formatDate(snapshot.created_at)}</p>
            </div>
            <div class="preview-table-container">
                <table class="preview-table">
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>SKU</th>
                            <th>Quantity</th>
                            <th>Category</th>
                            <th>Location</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${items.slice(0, 100).map(item => `
                            <tr>
                                <td>${escapeHtml(item.name || '')}</td>
                                <td>${escapeHtml(item.sku || '')}</td>
                                <td>${item.quantity || 0}</td>
                                <td>${escapeHtml(item.category || '')}</td>
                                <td>${escapeHtml(item.location || '')}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
                ${items.length > 100 ? `
                    <p class="preview-truncated">Showing first 100 of ${items.length} items</p>
                ` : ''}
            </div>
        `;
        
        document.getElementById('preview-snapshot-modal').hidden = false;
    }

    showRestoreModal(snapshotId) {
        this.selectedSnapshotId = snapshotId;
        const snapshot = this.snapshots.find(s => s.id === snapshotId);
        
        const details = document.getElementById('restore-snapshot-details');
        details.innerHTML = `
            <p>You are about to restore:</p>
            <div class="restore-info">
                <strong>${escapeHtml(snapshot.name)}</strong><br>
                ${snapshot.item_count} items • ${snapshot.total_quantity?.toLocaleString() || 0} total quantity<br>
                Created ${formatDate(snapshot.created_at)}
            </div>
        `;
        
        document.getElementById('restore-snapshot-modal').hidden = false;
    }

    async restoreSnapshot() {
        if (!this.selectedSnapshotId) return;
        
        const mode = document.querySelector('input[name="restore-mode"]:checked').value;
        
        const btn = document.getElementById('confirm-restore-btn');
        btn.disabled = true;
        btn.textContent = 'Restoring...';
        
        try {
            const { data, error } = await SB.client
                .rpc('restore_inventory_snapshot', {
                    p_snapshot_id: this.selectedSnapshotId,
                    p_restore_mode: mode
                });
            
            if (error) throw error;
            
            showToast(
                `Restored ${data.items_restored} items` + 
                (data.items_skipped > 0 ? ` (${data.items_skipped} skipped)` : ''),
                'success'
            );
            
            document.getElementById('restore-snapshot-modal').hidden = true;
            await this.loadSnapshots();
            
        } catch (err) {
            console.error('Restore failed:', err);
            showToast('Restore failed: ' + err.message, 'error');
        } finally {
            btn.disabled = false;
            btn.textContent = 'Restore Snapshot';
        }
    }

    async deleteSnapshot(snapshotId) {
        if (!confirm('Are you sure you want to delete this snapshot? This cannot be undone.')) {
            return;
        }
        
        const { error } = await SB.client
            .rpc('delete_inventory_snapshot', { p_snapshot_id: snapshotId });
        
        if (error) {
            showToast('Failed to delete snapshot: ' + error.message, 'error');
            return;
        }
        
        showToast('Snapshot deleted', 'success');
        await this.loadSnapshots();
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
    const manager = new SnapshotsManager();
    manager.init();
});

export { SnapshotsManager };
```

### Snapshots CSS

```css
/* Snapshots Page Styles */

.snapshots-list {
    display: grid;
    gap: 16px;
    padding: 24px;
}

.snapshot-card {
    background: white;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 20px;
    transition: box-shadow 0.2s;
}

.snapshot-card:hover {
    box-shadow: 0 2px 8px rgba(0,0,0,0.1);
}

.snapshot-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 8px;
}

.snapshot-header h3 {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
}

.snapshot-date {
    font-size: 13px;
    color: #666;
}

.snapshot-description {
    color: #666;
    font-size: 14px;
    margin: 0 0 12px 0;
}

.snapshot-meta {
    display: flex;
    gap: 16px;
    font-size: 13px;
    color: #666;
    margin-bottom: 16px;
}

.snapshot-actions {
    display: flex;
    gap: 8px;
}

.btn-sm {
    padding: 6px 12px;
    font-size: 13px;
}

/* Restore Modal */
.modal-warning {
    border-top: 4px solid #f57c00;
}

.restore-options {
    margin: 16px 0;
}

.radio-option {
    display: block;
    padding: 12px;
    margin: 8px 0;
    border: 1px solid #e0e0e0;
    border-radius: 4px;
    cursor: pointer;
}

.radio-option:hover {
    background: #f5f5f5;
}

.radio-option input {
    margin-right: 8px;
}

.warning-text {
    background: #fff3e0;
    padding: 12px;
    border-radius: 4px;
    font-size: 13px;
    color: #e65100;
}

.restore-info {
    background: #f5f5f5;
    padding: 12px;
    border-radius: 4px;
    margin: 12px 0;
}

/* Preview Modal */
.modal-large .modal-content {
    max-width: 900px;
    max-height: 80vh;
    overflow: auto;
}

.preview-table-container {
    max-height: 400px;
    overflow: auto;
    margin-top: 16px;
}

.preview-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
}

.preview-table th,
.preview-table td {
    padding: 8px 12px;
    text-align: left;
    border-bottom: 1px solid #e0e0e0;
}

.preview-table th {
    background: #f5f5f5;
    position: sticky;
    top: 0;
}

.preview-truncated {
    text-align: center;
    color: #666;
    font-size: 13px;
    margin-top: 12px;
}

/* Empty State */
.empty-state {
    text-align: center;
    padding: 48px;
    color: #666;
}

.empty-state h3 {
    margin: 0 0 8px 0;
    color: #333;
}
```

---

# Part 2: Action Metrics Dashboard

## Overview

The Metrics Dashboard provides visibility into inventory activity and user engagement. Two views are supported:

| View | Audience | Scope |
|------|----------|-------|
| Company Dashboard | Admin, Super User | Single company activity |
| Platform Dashboard | Super User only | All companies, platform health |

### Metrics Tracked

| Category | Metrics |
|----------|---------|
| **Inventory Activity** | Items created, edited, deleted, restored |
| **Order Activity** | Orders created, completed, deleted |
| **User Activity** | Logins, invitations sent, role changes |
| **Data Health** | Total items, low stock alerts, snapshot count |

## Database Views & Functions

### Materialized View: Daily Activity Stats

```sql
-- Materialized view for fast dashboard queries
-- Refresh periodically via cron or on-demand

CREATE MATERIALIZED VIEW IF NOT EXISTS daily_activity_stats AS
SELECT 
    date_trunc('day', created_at)::date AS activity_date,
    company_id,
    action,
    COUNT(*) AS action_count
FROM audit_log
WHERE created_at >= now() - interval '90 days'
GROUP BY date_trunc('day', created_at)::date, company_id, action
ORDER BY activity_date DESC, company_id;

-- Index for fast lookups
CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_stats_date_company_action 
ON daily_activity_stats(activity_date, company_id, action);

CREATE INDEX IF NOT EXISTS idx_daily_stats_company 
ON daily_activity_stats(company_id);

-- Function to refresh the view
CREATE OR REPLACE FUNCTION refresh_daily_activity_stats()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY daily_activity_stats;
END;
$$;
```

### Get Company Metrics

```sql
CREATE OR REPLACE FUNCTION get_company_metrics(
    p_company_id UUID,
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_user_role TEXT;
    v_result JSONB;
BEGIN
    v_user_id := auth.uid();
    
    -- Verify user has access and is admin+
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = p_company_id
      AND user_id = v_user_id
      AND deleted_at IS NULL;
    
    IF v_user_role NOT IN ('super_user', 'admin') THEN
        RAISE EXCEPTION 'Permission denied: admin role required';
    END IF;
    
    SELECT jsonb_build_object(
        -- Current state
        'current', jsonb_build_object(
            'total_items', (
                SELECT COUNT(*) FROM inventory_items 
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'total_quantity', (
                SELECT COALESCE(SUM(quantity), 0) FROM inventory_items 
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'low_stock_count', (
                SELECT COUNT(*) FROM inventory_items 
                WHERE company_id = p_company_id 
                  AND deleted_at IS NULL
                  AND reorder_point IS NOT NULL
                  AND quantity <= reorder_point
            ),
            'active_members', (
                SELECT COUNT(*) FROM company_members 
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'pending_invitations', (
                SELECT COUNT(*) FROM invitations 
                WHERE company_id = p_company_id 
                  AND status = 'pending'
                  AND expires_at > now()
            ),
            'snapshot_count', (
                SELECT COUNT(*) FROM inventory_snapshots 
                WHERE company_id = p_company_id
            )
        ),
        
        -- Activity over time period
        'activity', jsonb_build_object(
            'items_created', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'insert' 
                  AND table_name = 'inventory_items'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'items_updated', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'update' 
                  AND table_name = 'inventory_items'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'items_deleted', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'soft_delete' 
                  AND table_name = 'inventory_items'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'items_restored', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'restore' 
                  AND table_name = 'inventory_items'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'orders_created', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'insert' 
                  AND table_name = 'orders'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'snapshots_created', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'snapshot_created'
                  AND created_at >= now() - (p_days || ' days')::interval
            ),
            'snapshots_restored', (
                SELECT COUNT(*) FROM audit_log 
                WHERE company_id = p_company_id 
                  AND action = 'snapshot_restored'
                  AND created_at >= now() - (p_days || ' days')::interval
            )
        ),
        
        -- Daily breakdown for charts
        'daily_activity', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'date', activity_date,
                    'action', action,
                    'count', action_count
                )
                ORDER BY activity_date DESC
            ), '[]'::jsonb)
            FROM daily_activity_stats
            WHERE company_id = p_company_id
              AND activity_date >= (now() - (p_days || ' days')::interval)::date
        ),
        
        -- Top users by activity
        'top_users', (
            SELECT COALESCE(jsonb_agg(u), '[]'::jsonb)
            FROM (
                SELECT 
                    p.email,
                    COUNT(*) AS action_count
                FROM audit_log a
                JOIN profiles p ON p.id = a.user_id
                WHERE a.company_id = p_company_id
                  AND a.created_at >= now() - (p_days || ' days')::interval
                GROUP BY p.email
                ORDER BY action_count DESC
                LIMIT 5
            ) u
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
```

### Get Platform Metrics (Super User Only)

```sql
CREATE OR REPLACE FUNCTION get_platform_metrics(
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_is_super_user BOOLEAN;
    v_result JSONB;
BEGIN
    v_user_id := auth.uid();
    
    -- Verify Super User
    SELECT EXISTS (
        SELECT 1 FROM company_members
        WHERE user_id = v_user_id
          AND role = 'super_user'
          AND deleted_at IS NULL
    ) INTO v_is_super_user;
    
    IF NOT v_is_super_user THEN
        RAISE EXCEPTION 'Permission denied: Super User required';
    END IF;
    
    SELECT jsonb_build_object(
        -- Platform overview
        'platform', jsonb_build_object(
            'total_companies', (SELECT COUNT(*) FROM companies WHERE deleted_at IS NULL),
            'total_users', (SELECT COUNT(DISTINCT user_id) FROM company_members WHERE deleted_at IS NULL),
            'total_items', (SELECT COUNT(*) FROM inventory_items WHERE deleted_at IS NULL),
            'total_orders', (SELECT COUNT(*) FROM orders WHERE deleted_at IS NULL)
        ),
        
        -- Activity summary
        'activity', jsonb_build_object(
            'total_actions', (
                SELECT COUNT(*) FROM audit_log 
                WHERE created_at >= now() - (p_days || ' days')::interval
            ),
            'active_companies', (
                SELECT COUNT(DISTINCT company_id) FROM audit_log 
                WHERE created_at >= now() - (p_days || ' days')::interval
            ),
            'active_users', (
                SELECT COUNT(DISTINCT user_id) FROM audit_log 
                WHERE created_at >= now() - (p_days || ' days')::interval
            )
        ),
        
        -- Company breakdown
        'companies', (
            SELECT COALESCE(jsonb_agg(c), '[]'::jsonb)
            FROM (
                SELECT 
                    co.id,
                    co.name,
                    (SELECT COUNT(*) FROM company_members cm 
                     WHERE cm.company_id = co.id AND cm.deleted_at IS NULL) AS member_count,
                    (SELECT COUNT(*) FROM inventory_items ii 
                     WHERE ii.company_id = co.id AND ii.deleted_at IS NULL) AS item_count,
                    (SELECT COUNT(*) FROM audit_log al 
                     WHERE al.company_id = co.id 
                       AND al.created_at >= now() - (p_days || ' days')::interval) AS recent_actions
                FROM companies co
                WHERE co.deleted_at IS NULL
                ORDER BY recent_actions DESC
                LIMIT 20
            ) c
        ),
        
        -- Daily platform activity
        'daily_activity', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'date', activity_date,
                    'total_actions', total_actions,
                    'unique_companies', unique_companies
                )
                ORDER BY activity_date DESC
            ), '[]'::jsonb)
            FROM (
                SELECT 
                    activity_date,
                    SUM(action_count) AS total_actions,
                    COUNT(DISTINCT company_id) AS unique_companies
                FROM daily_activity_stats
                WHERE activity_date >= (now() - (p_days || ' days')::interval)::date
                GROUP BY activity_date
            ) d
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
```

## Frontend Implementation

### Dashboard Page (`/pages/dashboard.html`)

```html
<div id="dashboard-page" class="page">
    <header class="page-header">
        <div class="header-content">
            <h1 id="dashboard-title">Dashboard</h1>
            <div class="date-range-selector">
                <select id="date-range">
                    <option value="7">Last 7 days</option>
                    <option value="30" selected>Last 30 days</option>
                    <option value="90">Last 90 days</option>
                </select>
            </div>
        </div>
        <!-- Super User: company switcher for dashboard view -->
        <div id="dashboard-company-switcher" hidden>
            <select id="dashboard-company-select">
                <option value="platform">Platform Overview</option>
            </select>
        </div>
    </header>
    
    <!-- Current State Cards -->
    <section class="metrics-section">
        <h2>Current State</h2>
        <div class="metrics-grid" id="current-metrics">
            <!-- Populated by JS -->
        </div>
    </section>
    
    <!-- Activity Summary -->
    <section class="metrics-section">
        <h2>Activity Summary</h2>
        <div class="metrics-grid" id="activity-metrics">
            <!-- Populated by JS -->
        </div>
    </section>
    
    <!-- Activity Chart -->
    <section class="metrics-section">
        <h2>Activity Over Time</h2>
        <div class="chart-container">
            <canvas id="activity-chart"></canvas>
        </div>
    </section>
    
    <!-- Top Users (Company view) / Top Companies (Platform view) -->
    <section class="metrics-section" id="ranking-section">
        <h2 id="ranking-title">Top Contributors</h2>
        <div class="ranking-list" id="ranking-list">
            <!-- Populated by JS -->
        </div>
    </section>
</div>
```

### Dashboard JavaScript (`/js/dashboard.js`)

```javascript
import { SB } from '../services/supabase.js';
import { getCurrentCompanyId, getUserRole, getAllCompanies } from '../services/company.js';
import { escapeHtml } from '../utils/helpers.js';

class DashboardManager {
    constructor() {
        this.companyId = null;
        this.userRole = null;
        this.days = 30;
        this.chart = null;
        this.viewMode = 'company'; // 'company' or 'platform'
    }

    async init() {
        this.companyId = getCurrentCompanyId();
        this.userRole = getUserRole();
        
        // Super User can switch between company and platform view
        if (this.userRole === 'super_user') {
            await this.setupCompanySwitcher();
        }
        
        this.attachEventListeners();
        await this.loadMetrics();
    }

    async setupCompanySwitcher() {
        const container = document.getElementById('dashboard-company-switcher');
        const select = document.getElementById('dashboard-company-select');
        
        // Load all companies
        const companies = await getAllCompanies();
        
        companies.forEach(company => {
            const option = document.createElement('option');
            option.value = company.id;
            option.textContent = company.name;
            if (company.id === this.companyId) {
                option.selected = true;
            }
            select.appendChild(option);
        });
        
        container.hidden = false;
    }

    attachEventListeners() {
        // Date range change
        document.getElementById('date-range')?.addEventListener('change', (e) => {
            this.days = parseInt(e.target.value);
            this.loadMetrics();
        });
        
        // Company/Platform switcher
        document.getElementById('dashboard-company-select')?.addEventListener('change', (e) => {
            if (e.target.value === 'platform') {
                this.viewMode = 'platform';
            } else {
                this.viewMode = 'company';
                this.companyId = e.target.value;
            }
            this.loadMetrics();
        });
    }

    async loadMetrics() {
        if (this.viewMode === 'platform' && this.userRole === 'super_user') {
            await this.loadPlatformMetrics();
        } else {
            await this.loadCompanyMetrics();
        }
    }

    async loadCompanyMetrics() {
        document.getElementById('dashboard-title').textContent = 'Company Dashboard';
        
        const { data, error } = await SB.client
            .rpc('get_company_metrics', {
                p_company_id: this.companyId,
                p_days: this.days
            });
        
        if (error) {
            console.error('Failed to load metrics:', error);
            return;
        }
        
        this.renderCurrentMetrics(data.current);
        this.renderActivityMetrics(data.activity);
        this.renderActivityChart(data.daily_activity);
        this.renderTopUsers(data.top_users);
    }

    async loadPlatformMetrics() {
        document.getElementById('dashboard-title').textContent = 'Platform Dashboard';
        
        const { data, error } = await SB.client
            .rpc('get_platform_metrics', { p_days: this.days });
        
        if (error) {
            console.error('Failed to load platform metrics:', error);
            return;
        }
        
        this.renderPlatformMetrics(data.platform);
        this.renderPlatformActivity(data.activity);
        this.renderPlatformChart(data.daily_activity);
        this.renderTopCompanies(data.companies);
    }

    renderCurrentMetrics(current) {
        const container = document.getElementById('current-metrics');
        container.innerHTML = `
            <div class="metric-card">
                <div class="metric-value">${current.total_items.toLocaleString()}</div>
                <div class="metric-label">Total Items</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${current.total_quantity.toLocaleString()}</div>
                <div class="metric-label">Total Quantity</div>
            </div>
            <div class="metric-card ${current.low_stock_count > 0 ? 'metric-warning' : ''}">
                <div class="metric-value">${current.low_stock_count}</div>
                <div class="metric-label">Low Stock Alerts</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${current.active_members}</div>
                <div class="metric-label">Team Members</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${current.pending_invitations}</div>
                <div class="metric-label">Pending Invites</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${current.snapshot_count}</div>
                <div class="metric-label">Snapshots</div>
            </div>
        `;
    }

    renderActivityMetrics(activity) {
        const container = document.getElementById('activity-metrics');
        container.innerHTML = `
            <div class="metric-card metric-positive">
                <div class="metric-value">${activity.items_created}</div>
                <div class="metric-label">Items Created</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${activity.items_updated}</div>
                <div class="metric-label">Items Updated</div>
            </div>
            <div class="metric-card metric-negative">
                <div class="metric-value">${activity.items_deleted}</div>
                <div class="metric-label">Items Deleted</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${activity.items_restored}</div>
                <div class="metric-label">Items Restored</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${activity.orders_created}</div>
                <div class="metric-label">Orders Created</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${activity.snapshots_created}</div>
                <div class="metric-label">Snapshots Created</div>
            </div>
        `;
    }

    renderPlatformMetrics(platform) {
        const container = document.getElementById('current-metrics');
        container.innerHTML = `
            <div class="metric-card metric-primary">
                <div class="metric-value">${platform.total_companies}</div>
                <div class="metric-label">Total Companies</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${platform.total_users}</div>
                <div class="metric-label">Total Users</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${platform.total_items.toLocaleString()}</div>
                <div class="metric-label">Total Items</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${platform.total_orders.toLocaleString()}</div>
                <div class="metric-label">Total Orders</div>
            </div>
        `;
    }

    renderPlatformActivity(activity) {
        const container = document.getElementById('activity-metrics');
        container.innerHTML = `
            <div class="metric-card">
                <div class="metric-value">${activity.total_actions.toLocaleString()}</div>
                <div class="metric-label">Total Actions</div>
            </div>
            <div class="metric-card metric-positive">
                <div class="metric-value">${activity.active_companies}</div>
                <div class="metric-label">Active Companies</div>
            </div>
            <div class="metric-card">
                <div class="metric-value">${activity.active_users}</div>
                <div class="metric-label">Active Users</div>
            </div>
        `;
    }

    renderActivityChart(dailyActivity) {
        const ctx = document.getElementById('activity-chart');
        
        // Destroy existing chart
        if (this.chart) {
            this.chart.destroy();
        }
        
        // Process data for chart
        const dateMap = new Map();
        dailyActivity.forEach(item => {
            if (!dateMap.has(item.date)) {
                dateMap.set(item.date, { date: item.date, total: 0 });
            }
            dateMap.get(item.date).total += item.count;
        });
        
        const sorted = Array.from(dateMap.values()).sort((a, b) => 
            new Date(a.date) - new Date(b.date)
        );
        
        this.chart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: sorted.map(d => d.date),
                datasets: [{
                    label: 'Actions',
                    data: sorted.map(d => d.total),
                    borderColor: '#1976d2',
                    backgroundColor: 'rgba(25, 118, 210, 0.1)',
                    fill: true,
                    tension: 0.3
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                    y: {
                        beginAtZero: true,
                        ticks: { precision: 0 }
                    }
                },
                plugins: {
                    legend: { display: false }
                }
            }
        });
    }

    renderPlatformChart(dailyActivity) {
        const ctx = document.getElementById('activity-chart');
        
        if (this.chart) {
            this.chart.destroy();
        }
        
        const sorted = dailyActivity.sort((a, b) => 
            new Date(a.date) - new Date(b.date)
        );
        
        this.chart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: sorted.map(d => d.date),
                datasets: [
                    {
                        label: 'Total Actions',
                        data: sorted.map(d => d.total_actions),
                        borderColor: '#1976d2',
                        backgroundColor: 'rgba(25, 118, 210, 0.1)',
                        fill: true,
                        tension: 0.3,
                        yAxisID: 'y'
                    },
                    {
                        label: 'Active Companies',
                        data: sorted.map(d => d.unique_companies),
                        borderColor: '#43a047',
                        backgroundColor: 'rgba(67, 160, 71, 0.1)',
                        fill: false,
                        tension: 0.3,
                        yAxisID: 'y1'
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                    y: {
                        type: 'linear',
                        position: 'left',
                        beginAtZero: true,
                        ticks: { precision: 0 }
                    },
                    y1: {
                        type: 'linear',
                        position: 'right',
                        beginAtZero: true,
                        ticks: { precision: 0 },
                        grid: { drawOnChartArea: false }
                    }
                }
            }
        });
    }

    renderTopUsers(topUsers) {
        document.getElementById('ranking-title').textContent = 'Top Contributors';
        const container = document.getElementById('ranking-list');
        
        if (!topUsers || topUsers.length === 0) {
            container.innerHTML = '<p class="no-data">No activity in this period</p>';
            return;
        }
        
        container.innerHTML = topUsers.map((user, idx) => `
            <div class="ranking-item">
                <span class="ranking-position">${idx + 1}</span>
                <span class="ranking-name">${escapeHtml(user.email)}</span>
                <span class="ranking-value">${user.action_count} actions</span>
            </div>
        `).join('');
    }

    renderTopCompanies(companies) {
        document.getElementById('ranking-title').textContent = 'Most Active Companies';
        const container = document.getElementById('ranking-list');
        
        if (!companies || companies.length === 0) {
            container.innerHTML = '<p class="no-data">No companies found</p>';
            return;
        }
        
        container.innerHTML = companies.map((company, idx) => `
            <div class="ranking-item">
                <span class="ranking-position">${idx + 1}</span>
                <div class="ranking-details">
                    <span class="ranking-name">${escapeHtml(company.name)}</span>
                    <span class="ranking-meta">
                        ${company.member_count} members • ${company.item_count} items
                    </span>
                </div>
                <span class="ranking-value">${company.recent_actions} actions</span>
            </div>
        `).join('');
    }
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    const dashboard = new DashboardManager();
    dashboard.init();
});

export { DashboardManager };
```

### Dashboard CSS

```css
/* Dashboard Styles */

.metrics-section {
    margin-bottom: 32px;
    padding: 0 24px;
}

.metrics-section h2 {
    font-size: 16px;
    font-weight: 600;
    color: #333;
    margin-bottom: 16px;
}

.metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 16px;
}

.metric-card {
    background: white;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 20px;
    text-align: center;
}

.metric-value {
    font-size: 28px;
    font-weight: 700;
    color: #333;
    margin-bottom: 4px;
}

.metric-label {
    font-size: 13px;
    color: #666;
}

.metric-card.metric-positive {
    border-left: 4px solid #43a047;
}

.metric-card.metric-negative {
    border-left: 4px solid #e53935;
}

.metric-card.metric-warning {
    border-left: 4px solid #f57c00;
    background: #fff8e1;
}

.metric-card.metric-primary {
    border-left: 4px solid #1976d2;
    background: #e3f2fd;
}

/* Chart */
.chart-container {
    background: white;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 20px;
    height: 300px;
}

/* Rankings */
.ranking-list {
    background: white;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    overflow: hidden;
}

.ranking-item {
    display: flex;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid #e0e0e0;
}

.ranking-item:last-child {
    border-bottom: none;
}

.ranking-position {
    width: 28px;
    height: 28px;
    background: #e0e0e0;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 600;
    font-size: 13px;
    margin-right: 12px;
}

.ranking-item:nth-child(1) .ranking-position {
    background: #ffd700;
    color: #333;
}

.ranking-item:nth-child(2) .ranking-position {
    background: #c0c0c0;
}

.ranking-item:nth-child(3) .ranking-position {
    background: #cd7f32;
    color: white;
}

.ranking-details {
    flex: 1;
    display: flex;
    flex-direction: column;
}

.ranking-name {
    flex: 1;
    font-weight: 500;
}

.ranking-meta {
    font-size: 12px;
    color: #666;
}

.ranking-value {
    font-size: 13px;
    color: #666;
}

.no-data {
    padding: 24px;
    text-align: center;
    color: #666;
}

/* Date Range Selector */
.date-range-selector select {
    padding: 8px 12px;
    border: 1px solid #e0e0e0;
    border-radius: 4px;
    font-size: 14px;
}

/* Company Switcher */
#dashboard-company-switcher {
    margin-left: auto;
}

#dashboard-company-select {
    padding: 8px 12px;
    border: 1px solid #e0e0e0;
    border-radius: 4px;
    font-size: 14px;
    min-width: 200px;
}
```

---

# Part 3: Security Testing Checklist

## Overview

Before production launch, all RLS policies and security measures must be validated. This section provides test cases and verification steps.

## Test Environment Setup

```javascript
// test/security/setup.js

/**
 * Security Test Utilities
 * 
 * Creates test users with different roles to verify RLS policies
 */

import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

// Admin client bypasses RLS
const adminClient = createClient(supabaseUrl, serviceRoleKey);

// Test users (create these in your test environment)
export const TEST_USERS = {
    SUPER_USER: {
        email: 'test-super@modulus-software.com',
        password: 'TestPassword123!',
        role: 'super_user'
    },
    ADMIN_COMPANY_A: {
        email: 'test-admin-a@example.com',
        password: 'TestPassword123!',
        role: 'admin',
        company: 'Company A'
    },
    MEMBER_COMPANY_A: {
        email: 'test-member-a@example.com',
        password: 'TestPassword123!',
        role: 'member',
        company: 'Company A'
    },
    VIEWER_COMPANY_A: {
        email: 'test-viewer-a@example.com',
        password: 'TestPassword123!',
        role: 'viewer',
        company: 'Company A'
    },
    ADMIN_COMPANY_B: {
        email: 'test-admin-b@example.com',
        password: 'TestPassword123!',
        role: 'admin',
        company: 'Company B'
    }
};

export async function createAuthenticatedClient(user) {
    const { data, error } = await adminClient.auth.signInWithPassword({
        email: user.email,
        password: user.password
    });
    
    if (error) throw error;
    
    return createClient(supabaseUrl, process.env.SUPABASE_ANON_KEY, {
        global: {
            headers: {
                Authorization: `Bearer ${data.session.access_token}`
            }
        }
    });
}
```

## RLS Negative Tests

### Test 1: Cross-Company Data Isolation

```javascript
// test/security/cross-company-isolation.test.js

import { describe, it, expect, beforeAll } from 'vitest';
import { createAuthenticatedClient, TEST_USERS } from './setup.js';

describe('Cross-Company Data Isolation', () => {
    let clientA, clientB;
    let companyAId, companyBId;
    let itemInCompanyA;

    beforeAll(async () => {
        clientA = await createAuthenticatedClient(TEST_USERS.ADMIN_COMPANY_A);
        clientB = await createAuthenticatedClient(TEST_USERS.ADMIN_COMPANY_B);
        
        // Get company IDs
        const { data: membershipA } = await clientA.rpc('get_my_companies');
        const { data: membershipB } = await clientB.rpc('get_my_companies');
        
        companyAId = membershipA[0].company_id;
        companyBId = membershipB[0].company_id;
        
        // Create test item in Company A
        const { data } = await clientA
            .from('inventory_items')
            .insert({ 
                company_id: companyAId,
                name: 'Test Item A',
                sku: 'TEST-A-001',
                quantity: 10
            })
            .select()
            .single();
        
        itemInCompanyA = data;
    });

    it('Company B cannot SELECT items from Company A', async () => {
        const { data, error } = await clientB
            .from('inventory_items')
            .select('*')
            .eq('id', itemInCompanyA.id);
        
        expect(error).toBeNull();
        expect(data).toHaveLength(0); // RLS should filter it out
    });

    it('Company B cannot UPDATE items in Company A', async () => {
        const { error } = await clientB
            .from('inventory_items')
            .update({ name: 'Hacked!' })
            .eq('id', itemInCompanyA.id);
        
        // Should either error or affect 0 rows
        // RLS typically returns success but affects 0 rows
    });

    it('Company B cannot DELETE items from Company A', async () => {
        // Note: Hard deletes should be blocked anyway
        const { error } = await clientB
            .from('inventory_items')
            .delete()
            .eq('id', itemInCompanyA.id);
        
        // Verify item still exists via admin client
    });

    it('Company B cannot INSERT items into Company A', async () => {
        const { error } = await clientB
            .from('inventory_items')
            .insert({
                company_id: companyAId, // Trying to insert into Company A
                name: 'Malicious Item',
                sku: 'HACK-001',
                quantity: 999
            });
        
        expect(error).not.toBeNull();
    });

    it('Company B cannot view Company A audit logs', async () => {
        const { data } = await clientB
            .from('audit_log')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });

    it('Company B cannot view Company A snapshots', async () => {
        const { data } = await clientB
            .from('inventory_snapshots')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });

    it('Company B cannot view Company A members', async () => {
        const { data } = await clientB
            .from('company_members')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });
});
```

### Test 2: Role-Based Access Control

```javascript
// test/security/rbac.test.js

import { describe, it, expect, beforeAll } from 'vitest';
import { createAuthenticatedClient, TEST_USERS } from './setup.js';

describe('Role-Based Access Control', () => {
    let superUserClient, adminClient, memberClient, viewerClient;
    let companyId, testItemId;

    beforeAll(async () => {
        superUserClient = await createAuthenticatedClient(TEST_USERS.SUPER_USER);
        adminClient = await createAuthenticatedClient(TEST_USERS.ADMIN_COMPANY_A);
        memberClient = await createAuthenticatedClient(TEST_USERS.MEMBER_COMPANY_A);
        viewerClient = await createAuthenticatedClient(TEST_USERS.VIEWER_COMPANY_A);
        
        // Get company ID
        const { data } = await adminClient.rpc('get_my_companies');
        companyId = data[0].company_id;
        
        // Create test item
        const { data: item } = await adminClient
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'RBAC Test Item',
                sku: 'RBAC-001',
                quantity: 10
            })
            .select()
            .single();
        
        testItemId = item.id;
    });

    describe('Viewer Role', () => {
        it('CAN view items', async () => {
            const { data, error } = await viewerClient
                .from('inventory_items')
                .select('*')
                .eq('company_id', companyId);
            
            expect(error).toBeNull();
            expect(data.length).toBeGreaterThan(0);
        });

        it('CANNOT create items', async () => {
            const { error } = await viewerClient
                .from('inventory_items')
                .insert({
                    company_id: companyId,
                    name: 'Viewer Created',
                    sku: 'VIEW-001',
                    quantity: 1
                });
            
            expect(error).not.toBeNull();
        });

        it('CANNOT update items', async () => {
            const { error, count } = await viewerClient
                .from('inventory_items')
                .update({ quantity: 999 })
                .eq('id', testItemId);
            
            // Should either error or update 0 rows
        });

        it('CANNOT soft delete items', async () => {
            const { error } = await viewerClient
                .rpc('soft_delete_item', { p_item_id: testItemId });
            
            expect(error).not.toBeNull();
        });

        it('CANNOT invite members', async () => {
            const { error } = await viewerClient
                .rpc('create_invitation', {
                    p_company_id: companyId,
                    p_email: 'newuser@example.com',
                    p_role: 'member'
                });
            
            expect(error).not.toBeNull();
        });

        it('CANNOT access audit log', async () => {
            const { data } = await viewerClient
                .from('audit_log')
                .select('*')
                .eq('company_id', companyId);
            
            expect(data).toHaveLength(0);
        });
    });

    describe('Member Role', () => {
        it('CAN create items', async () => {
            const { data, error } = await memberClient
                .from('inventory_items')
                .insert({
                    company_id: companyId,
                    name: 'Member Created',
                    sku: 'MEM-001',
                    quantity: 5
                })
                .select()
                .single();
            
            expect(error).toBeNull();
            expect(data).not.toBeNull();
        });

        it('CAN update items', async () => {
            const { error } = await memberClient
                .from('inventory_items')
                .update({ quantity: 15 })
                .eq('id', testItemId);
            
            expect(error).toBeNull();
        });

        it('CANNOT soft delete items', async () => {
            const { error } = await memberClient
                .rpc('soft_delete_item', { p_item_id: testItemId });
            
            expect(error).not.toBeNull();
        });

        it('CANNOT invite members', async () => {
            const { error } = await memberClient
                .rpc('create_invitation', {
                    p_company_id: companyId,
                    p_email: 'another@example.com',
                    p_role: 'member'
                });
            
            expect(error).not.toBeNull();
        });

        it('CANNOT access audit log', async () => {
            const { data } = await memberClient
                .from('audit_log')
                .select('*')
                .eq('company_id', companyId);
            
            expect(data).toHaveLength(0);
        });
    });

    describe('Admin Role', () => {
        it('CAN soft delete items', async () => {
            // Create item to delete
            const { data: item } = await adminClient
                .from('inventory_items')
                .insert({
                    company_id: companyId,
                    name: 'To Delete',
                    sku: 'DEL-001',
                    quantity: 1
                })
                .select()
                .single();
            
            const { error } = await adminClient
                .rpc('soft_delete_item', { p_item_id: item.id });
            
            expect(error).toBeNull();
        });

        it('CAN restore items', async () => {
            // Restore the deleted item
            const { data: deleted } = await adminClient
                .from('inventory_items')
                .select('*')
                .eq('sku', 'DEL-001')
                .is('deleted_at', 'not.null')
                .single();
            
            const { error } = await adminClient
                .rpc('restore_item', { p_item_id: deleted.id });
            
            expect(error).toBeNull();
        });

        it('CAN invite members', async () => {
            const { data, error } = await adminClient
                .rpc('create_invitation', {
                    p_company_id: companyId,
                    p_email: 'invited@example.com',
                    p_role: 'member'
                });
            
            expect(error).toBeNull();
        });

        it('CAN view audit log', async () => {
            const { data, error } = await adminClient
                .from('audit_log')
                .select('*')
                .eq('company_id', companyId);
            
            expect(error).toBeNull();
            expect(data.length).toBeGreaterThan(0);
        });

        it('CAN create snapshots', async () => {
            const { data, error } = await adminClient
                .rpc('create_inventory_snapshot', {
                    p_company_id: companyId,
                    p_name: 'Admin Test Snapshot'
                });
            
            expect(error).toBeNull();
        });

        it('CANNOT restore snapshots', async () => {
            // Get a snapshot
            const { data: snapshots } = await adminClient
                .from('inventory_snapshots')
                .select('id')
                .eq('company_id', companyId)
                .limit(1);
            
            if (snapshots.length > 0) {
                const { error } = await adminClient
                    .rpc('restore_inventory_snapshot', {
                        p_snapshot_id: snapshots[0].id
                    });
                
                expect(error).not.toBeNull();
            }
        });

        it('CANNOT change member to Super User', async () => {
            // Get a member
            const { data: members } = await adminClient
                .from('company_members')
                .select('id, user_id')
                .eq('company_id', companyId)
                .eq('role', 'member')
                .limit(1);
            
            if (members.length > 0) {
                const { error } = await adminClient
                    .rpc('change_member_role', {
                        p_member_id: members[0].id,
                        p_new_role: 'super_user'
                    });
                
                expect(error).not.toBeNull();
            }
        });
    });

    describe('Super User Role', () => {
        it('CAN restore snapshots', async () => {
            // Create a snapshot first
            const { data: snapshotId } = await superUserClient
                .rpc('create_inventory_snapshot', {
                    p_company_id: companyId,
                    p_name: 'SU Restore Test'
                });
            
            const { data, error } = await superUserClient
                .rpc('restore_inventory_snapshot', {
                    p_snapshot_id: snapshotId,
                    p_restore_mode: 'merge'
                });
            
            expect(error).toBeNull();
            expect(data.success).toBe(true);
        });

        it('CAN view all companies', async () => {
            const { data, error } = await superUserClient
                .rpc('get_all_companies');
            
            expect(error).toBeNull();
            expect(data.length).toBeGreaterThan(0);
        });

        it('CAN access platform metrics', async () => {
            const { data, error } = await superUserClient
                .rpc('get_platform_metrics', { p_days: 30 });
            
            expect(error).toBeNull();
            expect(data).not.toBeNull();
        });
    });
});
```

### Test 3: Hard Delete Prevention

```javascript
// test/security/hard-delete-prevention.test.js

import { describe, it, expect, beforeAll } from 'vitest';
import { createAuthenticatedClient, TEST_USERS, adminClient } from './setup.js';

describe('Hard Delete Prevention', () => {
    let client;
    let companyId, testItemId;

    beforeAll(async () => {
        client = await createAuthenticatedClient(TEST_USERS.SUPER_USER);
        
        const { data } = await client.rpc('get_my_companies');
        companyId = data[0].company_id;
        
        // Create test item
        const { data: item } = await client
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'Hard Delete Test',
                sku: 'HARD-DEL-001',
                quantity: 1
            })
            .select()
            .single();
        
        testItemId = item.id;
    });

    it('Direct DELETE on inventory_items should be blocked', async () => {
        const { error } = await client
            .from('inventory_items')
            .delete()
            .eq('id', testItemId);
        
        // Should error - DELETE grant should not exist
        expect(error).not.toBeNull();
    });

    it('Direct DELETE on orders should be blocked', async () => {
        // Create test order
        const { data: order } = await client
            .from('orders')
            .insert({
                company_id: companyId,
                order_type: 'test',
                status: 'pending'
            })
            .select()
            .single();
        
        const { error } = await client
            .from('orders')
            .delete()
            .eq('id', order.id);
        
        expect(error).not.toBeNull();
    });

    it('Direct DELETE on company_members should be blocked', async () => {
        // Try to delete own membership (shouldn't work)
        const { error } = await client
            .from('company_members')
            .delete()
            .eq('company_id', companyId);
        
        expect(error).not.toBeNull();
    });

    it('Soft delete RPC should work instead', async () => {
        const { error } = await client
            .rpc('soft_delete_item', { p_item_id: testItemId });
        
        expect(error).toBeNull();
        
        // Verify item is soft deleted, not hard deleted
        const { data } = await adminClient
            .from('inventory_items')
            .select('*')
            .eq('id', testItemId)
            .single();
        
        expect(data).not.toBeNull();
        expect(data.deleted_at).not.toBeNull();
    });
});
```

## Audit Verification Tests

```javascript
// test/security/audit-verification.test.js

import { describe, it, expect, beforeAll } from 'vitest';
import { createAuthenticatedClient, TEST_USERS, adminClient } from './setup.js';

describe('Audit Log Verification', () => {
    let client;
    let companyId;

    beforeAll(async () => {
        client = await createAuthenticatedClient(TEST_USERS.ADMIN_COMPANY_A);
        
        const { data } = await client.rpc('get_my_companies');
        companyId = data[0].company_id;
    });

    it('Item creation is logged', async () => {
        const { data: item } = await client
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'Audit Test Item',
                sku: 'AUDIT-001',
                quantity: 1
            })
            .select()
            .single();
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('record_id', item.id)
            .eq('action', 'insert')
            .single();
        
        expect(logs).not.toBeNull();
        expect(logs.table_name).toBe('inventory_items');
    });

    it('Item update is logged', async () => {
        // Create and update item
        const { data: item } = await client
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'Update Audit Test',
                sku: 'AUDIT-002',
                quantity: 1
            })
            .select()
            .single();
        
        await client
            .from('inventory_items')
            .update({ quantity: 10 })
            .eq('id', item.id);
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('record_id', item.id)
            .eq('action', 'update');
        
        expect(logs.length).toBeGreaterThan(0);
    });

    it('Soft delete is logged', async () => {
        // Create and soft delete
        const { data: item } = await client
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'Delete Audit Test',
                sku: 'AUDIT-003',
                quantity: 1
            })
            .select()
            .single();
        
        await client.rpc('soft_delete_item', { p_item_id: item.id });
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('record_id', item.id)
            .eq('action', 'soft_delete');
        
        expect(logs.length).toBe(1);
    });

    it('Restore is logged', async () => {
        // Create, delete, and restore
        const { data: item } = await client
            .from('inventory_items')
            .insert({
                company_id: companyId,
                name: 'Restore Audit Test',
                sku: 'AUDIT-004',
                quantity: 1
            })
            .select()
            .single();
        
        await client.rpc('soft_delete_item', { p_item_id: item.id });
        await client.rpc('restore_item', { p_item_id: item.id });
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('record_id', item.id)
            .eq('action', 'restore');
        
        expect(logs.length).toBe(1);
    });

    it('Snapshot creation is logged', async () => {
        const { data: snapshotId } = await client
            .rpc('create_inventory_snapshot', {
                p_company_id: companyId,
                p_name: 'Audit Log Test Snapshot'
            });
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('record_id', snapshotId)
            .eq('action', 'snapshot_created');
        
        expect(logs.length).toBe(1);
    });

    it('Invitation creation is logged', async () => {
        const { data: invitation } = await client
            .rpc('create_invitation', {
                p_company_id: companyId,
                p_email: 'audit-invite-test@example.com',
                p_role: 'member'
            });
        
        // Check audit log
        const { data: logs } = await adminClient
            .from('audit_log')
            .select('*')
            .eq('action', 'invitation_created')
            .order('created_at', { ascending: false })
            .limit(1);
        
        expect(logs.length).toBe(1);
    });
});
```

## Manual Testing Checklist

### Pre-Launch Security Verification

```markdown
## Security Verification Checklist

### Cross-Company Isolation
- [ ] User from Company A cannot see Company B items
- [ ] User from Company A cannot see Company B orders
- [ ] User from Company A cannot see Company B members
- [ ] User from Company A cannot see Company B audit logs
- [ ] User from Company A cannot see Company B snapshots
- [ ] User from Company A cannot see Company B invitations
- [ ] Attempting to INSERT with wrong company_id fails
- [ ] Attempting to UPDATE records in other company fails

### Role Permissions
- [ ] Viewer: Can only view, cannot create/edit/delete
- [ ] Member: Can create and edit, cannot delete or manage users
- [ ] Admin: Can delete/restore, invite users, change roles (except SU)
- [ ] Admin: Cannot promote to Super User
- [ ] Admin: Cannot restore snapshots
- [ ] Super User: Full access including snapshot restore
- [ ] Super User: Can view all companies

### Hard Delete Prevention
- [ ] Direct DELETE query fails on inventory_items
- [ ] Direct DELETE query fails on orders
- [ ] Direct DELETE query fails on company_members
- [ ] Direct DELETE query fails on companies
- [ ] Only soft delete RPCs work

### Audit Completeness
- [ ] All item creates are logged
- [ ] All item updates are logged
- [ ] All soft deletes are logged
- [ ] All restores are logged
- [ ] All snapshot creates are logged
- [ ] All snapshot restores are logged
- [ ] All invitation creates are logged
- [ ] All role changes are logged
- [ ] Audit logs include user_id and timestamp

### Session Security
- [ ] Expired JWT tokens are rejected
- [ ] Invalid JWT tokens are rejected
- [ ] Anonymous users cannot access authenticated routes
- [ ] RLS policies use auth.uid() correctly

### Data Integrity
- [ ] Soft deleted items don't appear in normal queries
- [ ] Soft deleted items appear in trash view for admins
- [ ] Restored items reappear in normal queries
- [ ] Snapshot restore creates pre-restore backup

### Edge Cases
- [ ] Empty company (no items) doesn't break dashboards
- [ ] User with no company membership sees appropriate error
- [ ] Concurrent snapshot restores handled safely
- [ ] Very large snapshots (1000+ items) restore correctly
```

---

# Part 4: Role Engine

## Overview

The Role Engine centralizes permission management, enabling UI-based configuration of role capabilities without code changes.

*(Note: Full Role Engine specification follows - this is the same content from the original Phase 1B Role Engine document)*

## Permission Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ROLE ENGINE ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         PERMISSIONS TABLE                            │   │
│  │  Atomic capabilities that can be granted                             │   │
│  ├─────────────────────────────────────────────────────────────────────┤   │
│  │  id          │ key                    │ category    │ description   │   │
│  │  ────────────┼────────────────────────┼─────────────┼───────────────│   │
│  │  uuid        │ items:view             │ inventory   │ View items    │   │
│  │  uuid        │ items:create           │ inventory   │ Create items  │   │
│  │  uuid        │ items:edit             │ inventory   │ Edit items    │   │
│  │  uuid        │ items:delete           │ inventory   │ Soft delete   │   │
│  │  ...         │ ...                    │ ...         │ ...           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      ROLE_PERMISSIONS TABLE                          │   │
│  │  Maps roles to their granted permissions                             │   │
│  ├─────────────────────────────────────────────────────────────────────┤   │
│  │  role          │ permission_id │ granted_by      │ granted_at       │   │
│  │  ──────────────┼───────────────┼─────────────────┼──────────────────│   │
│  │  super_user    │ (items:view)  │ SYSTEM          │ 2024-12-01       │   │
│  │  super_user    │ (items:edit)  │ SYSTEM          │ 2024-12-01       │   │
│  │  admin         │ (items:view)  │ SYSTEM          │ 2024-12-01       │   │
│  │  ...           │ ...           │ ...             │ ...              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      PERMISSION ENGINE (RPC)                         │   │
│  │  `check_permission(p_company_id, p_permission_key)` → boolean        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      FRONTEND PERMISSION LAYER                       │   │
│  │  Cached permissions object loaded on app init                        │   │
│  │  permissions.can('items:delete')  → true/false (sync)                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Permission Taxonomy

### Naming Convention

```
{resource}:{action}

Examples:
  items:view
  items:create
  items:edit
  items:delete
  members:invite
  audit_log:view
```

### Complete Permission Matrix

| Permission Key | Category | Super User | Admin | Member | Viewer |
|----------------|----------|:----------:|:-----:|:------:|:------:|
| `items:view` | inventory | ✅ | ✅ | ✅ | ✅ |
| `items:create` | inventory | ✅ | ✅ | ✅ | ❌ |
| `items:edit` | inventory | ✅ | ✅ | ✅ | ❌ |
| `items:delete` | inventory | ✅ | ✅ | ❌ | ❌ |
| `items:restore` | inventory | ✅ | ✅ | ❌ | ❌ |
| `items:hard_delete` | inventory | ✅ | ❌ | ❌ | ❌ |
| `items:export` | inventory | ✅ | ✅ | ✅ | ✅ |
| `items:import` | inventory | ✅ | ✅ | ❌ | ❌ |
| `orders:view` | orders | ✅ | ✅ | ✅ | ✅ |
| `orders:create` | orders | ✅ | ✅ | ✅ | ❌ |
| `orders:edit` | orders | ✅ | ✅ | ✅ | ❌ |
| `orders:delete` | orders | ✅ | ✅ | ❌ | ❌ |
| `orders:restore` | orders | ✅ | ✅ | ❌ | ❌ |
| `members:view` | members | ✅ | ✅ | ✅ | ✅ |
| `members:invite` | members | ✅ | ✅ | ❌ | ❌ |
| `members:remove` | members | ✅ | ✅ | ❌ | ❌ |
| `members:change_role` | members | ✅ | ✅* | ❌ | ❌ |
| `company:view_settings` | company | ✅ | ✅ | ❌ | ❌ |
| `company:edit_settings` | company | ✅ | ✅ | ❌ | ❌ |
| `company:view_billing` | company | ✅ | ❌ | ❌ | ❌ |
| `company:manage_billing` | company | ✅ | ❌ | ❌ | ❌ |
| `audit_log:view` | audit | ✅ | ✅ | ❌ | ❌ |
| `audit_log:export` | audit | ✅ | ❌ | ❌ | ❌ |
| `trash:view` | audit | ✅ | ✅ | ❌ | ❌ |
| `snapshots:view` | audit | ✅ | ✅ | ❌ | ❌ |
| `snapshots:create` | audit | ✅ | ✅ | ❌ | ❌ |
| `snapshots:restore` | audit | ✅ | ❌ | ❌ | ❌ |
| `snapshots:delete` | audit | ✅ | ✅ | ❌ | ❌ |
| `platform:view_all_companies` | platform | ✅ | ❌ | ❌ | ❌ |
| `platform:manage_roles` | platform | ✅ | ❌ | ❌ | ❌ |
| `platform:view_metrics` | platform | ✅ | ❌ | ❌ | ❌ |

*Admin can change roles but cannot promote to Super User

## Database Schema

### SQL Migration

```sql
-- ============================================================================
-- PHASE 1B: ROLE ENGINE MIGRATION
-- ============================================================================

BEGIN;

-- 1. CREATE ROLE ENUM (if not exists)
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('super_user', 'admin', 'member', 'viewer');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 2. PERMISSIONS TABLE
CREATE TABLE IF NOT EXISTS permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT UNIQUE NOT NULL,
    category TEXT NOT NULL,
    display_name TEXT NOT NULL,
    description TEXT,
    is_system BOOLEAN DEFAULT true,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_permissions_key ON permissions(key);
CREATE INDEX IF NOT EXISTS idx_permissions_category ON permissions(category);

-- 3. ROLE_PERMISSIONS TABLE
CREATE TABLE IF NOT EXISTS role_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role user_role NOT NULL,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    is_system BOOLEAN DEFAULT true,
    granted_by UUID REFERENCES auth.users(id),
    granted_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(role, permission_id)
);

CREATE INDEX IF NOT EXISTS idx_role_permissions_role ON role_permissions(role);

-- 4. AUDIT LOG FOR PERMISSION CHANGES
CREATE TABLE IF NOT EXISTS role_permission_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role user_role NOT NULL,
    permission_key TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('granted', 'revoked')),
    changed_by UUID REFERENCES auth.users(id),
    changed_at TIMESTAMPTZ DEFAULT now(),
    reason TEXT
);

-- 5. SEED PERMISSIONS
INSERT INTO permissions (key, category, display_name, description, sort_order) VALUES
    -- Inventory
    ('items:view', 'inventory', 'View Items', 'View inventory items', 10),
    ('items:create', 'inventory', 'Create Items', 'Add new items', 20),
    ('items:edit', 'inventory', 'Edit Items', 'Modify items', 30),
    ('items:delete', 'inventory', 'Delete Items', 'Soft delete items', 40),
    ('items:restore', 'inventory', 'Restore Items', 'Restore from trash', 50),
    ('items:hard_delete', 'inventory', 'Permanently Delete', 'Delete from trash', 60),
    ('items:export', 'inventory', 'Export Items', 'Export to CSV', 70),
    ('items:import', 'inventory', 'Import Items', 'Import from CSV', 80),
    -- Orders
    ('orders:view', 'orders', 'View Orders', 'View orders', 10),
    ('orders:create', 'orders', 'Create Orders', 'Create orders', 20),
    ('orders:edit', 'orders', 'Edit Orders', 'Modify orders', 30),
    ('orders:delete', 'orders', 'Delete Orders', 'Soft delete orders', 40),
    ('orders:restore', 'orders', 'Restore Orders', 'Restore orders', 50),
    -- Members
    ('members:view', 'members', 'View Members', 'View team members', 10),
    ('members:invite', 'members', 'Invite Members', 'Send invitations', 20),
    ('members:remove', 'members', 'Remove Members', 'Remove from company', 30),
    ('members:change_role', 'members', 'Change Roles', 'Modify roles', 40),
    -- Company
    ('company:view_settings', 'company', 'View Settings', 'View company settings', 10),
    ('company:edit_settings', 'company', 'Edit Settings', 'Modify settings', 20),
    ('company:view_billing', 'company', 'View Billing', 'View billing info', 30),
    ('company:manage_billing', 'company', 'Manage Billing', 'Modify billing', 40),
    -- Audit
    ('audit_log:view', 'audit', 'View Audit Log', 'View activity log', 10),
    ('audit_log:export', 'audit', 'Export Audit Log', 'Export log', 20),
    ('trash:view', 'audit', 'View Trash', 'View deleted items', 30),
    ('snapshots:view', 'audit', 'View Snapshots', 'View snapshots', 40),
    ('snapshots:create', 'audit', 'Create Snapshots', 'Create snapshots', 50),
    ('snapshots:restore', 'audit', 'Restore Snapshots', 'Restore from snapshot', 60),
    ('snapshots:delete', 'audit', 'Delete Snapshots', 'Delete snapshots', 70),
    -- Platform
    ('platform:view_all_companies', 'platform', 'View All Companies', 'See all companies', 10),
    ('platform:manage_roles', 'platform', 'Manage Roles', 'Configure permissions', 20),
    ('platform:view_metrics', 'platform', 'View Metrics', 'Platform analytics', 30)
ON CONFLICT (key) DO NOTHING;

-- 6. SEED ROLE-PERMISSION MAPPINGS

-- Super User: ALL permissions
INSERT INTO role_permissions (role, permission_id, is_system)
SELECT 'super_user'::user_role, id, true FROM permissions
ON CONFLICT (role, permission_id) DO NOTHING;

-- Admin: Most except platform and dangerous
INSERT INTO role_permissions (role, permission_id, is_system)
SELECT 'admin'::user_role, id, true FROM permissions
WHERE category != 'platform'
  AND key NOT IN ('items:hard_delete', 'snapshots:restore', 'audit_log:export', 
                  'company:view_billing', 'company:manage_billing')
ON CONFLICT (role, permission_id) DO NOTHING;

-- Member: Basic CRUD
INSERT INTO role_permissions (role, permission_id, is_system)
SELECT 'member'::user_role, id, true FROM permissions
WHERE key IN ('items:view', 'items:create', 'items:edit', 'items:export',
              'orders:view', 'orders:create', 'orders:edit', 'members:view')
ON CONFLICT (role, permission_id) DO NOTHING;

-- Viewer: Read-only
INSERT INTO role_permissions (role, permission_id, is_system)
SELECT 'viewer'::user_role, id, true FROM permissions
WHERE key IN ('items:view', 'items:export', 'orders:view', 'members:view')
ON CONFLICT (role, permission_id) DO NOTHING;

-- 7. PERMISSION CHECK RPC
CREATE OR REPLACE FUNCTION check_permission(
    p_company_id UUID,
    p_permission_key TEXT
) RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_role user_role;
BEGIN
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = p_company_id
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF v_user_role IS NULL THEN
        RETURN false;
    END IF;
    
    RETURN EXISTS (
        SELECT 1
        FROM role_permissions rp
        JOIN permissions p ON p.id = rp.permission_id
        WHERE rp.role = v_user_role AND p.key = p_permission_key
    );
END;
$$;

-- 8. GET USER PERMISSIONS RPC
CREATE OR REPLACE FUNCTION get_user_permissions(
    p_company_id UUID
) RETURNS TABLE (permission_key TEXT)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_role user_role;
BEGIN
    SELECT role INTO v_user_role
    FROM company_members
    WHERE company_id = p_company_id
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF v_user_role IS NULL THEN RETURN; END IF;
    
    RETURN QUERY
    SELECT p.key
    FROM role_permissions rp
    JOIN permissions p ON p.id = rp.permission_id
    WHERE rp.role = v_user_role
    ORDER BY p.category, p.sort_order;
END;
$$;

-- 9. GET ROLE MATRIX (Super User UI)
CREATE OR REPLACE FUNCTION get_role_permissions_matrix()
RETURNS TABLE (
    permission_id UUID,
    permission_key TEXT,
    category TEXT,
    display_name TEXT,
    description TEXT,
    super_user_has BOOLEAN,
    admin_has BOOLEAN,
    member_has BOOLEAN,
    viewer_has BOOLEAN
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
    -- Verify Super User
    IF NOT EXISTS (
        SELECT 1 FROM company_members
        WHERE user_id = auth.uid() AND role = 'super_user' AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    RETURN QUERY
    SELECT 
        p.id,
        p.key,
        p.category,
        p.display_name,
        p.description,
        EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role = 'super_user' AND rp.permission_id = p.id),
        EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role = 'admin' AND rp.permission_id = p.id),
        EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role = 'member' AND rp.permission_id = p.id),
        EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role = 'viewer' AND rp.permission_id = p.id)
    FROM permissions p
    ORDER BY p.category, p.sort_order;
END;
$$;

-- 10. SET ROLE PERMISSION (Super User)
CREATE OR REPLACE FUNCTION set_role_permission(
    p_role user_role,
    p_permission_key TEXT,
    p_granted BOOLEAN,
    p_reason TEXT DEFAULT NULL
) RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_permission_id UUID;
BEGIN
    v_user_id := auth.uid();
    
    -- Only Super User can modify
    IF NOT EXISTS (
        SELECT 1 FROM company_members
        WHERE user_id = v_user_id AND role = 'super_user' AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Cannot modify Super User
    IF p_role = 'super_user' THEN
        RAISE EXCEPTION 'Cannot modify Super User permissions';
    END IF;
    
    SELECT id INTO v_permission_id FROM permissions WHERE key = p_permission_key;
    IF v_permission_id IS NULL THEN
        RAISE EXCEPTION 'Permission not found: %', p_permission_key;
    END IF;
    
    IF p_granted THEN
        INSERT INTO role_permissions (role, permission_id, is_system, granted_by)
        VALUES (p_role, v_permission_id, false, v_user_id)
        ON CONFLICT (role, permission_id) DO NOTHING;
    ELSE
        DELETE FROM role_permissions
        WHERE role = p_role AND permission_id = v_permission_id;
    END IF;
    
    -- Log change
    INSERT INTO role_permission_audit_log (role, permission_key, action, changed_by, reason)
    VALUES (p_role, p_permission_key, CASE WHEN p_granted THEN 'granted' ELSE 'revoked' END, v_user_id, p_reason);
    
    RETURN true;
END;
$$;

-- 11. RLS POLICIES
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permission_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "permissions_select_authenticated" ON permissions
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "role_permissions_select_authenticated" ON role_permissions
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "role_permission_audit_select_super_user" ON role_permission_audit_log
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM company_members
        WHERE user_id = auth.uid() AND role = 'super_user' AND deleted_at IS NULL
    ));

COMMIT;
```

## Frontend Permission Service

```javascript
// /services/permissions.js

import { SB } from './supabase.js';

class PermissionService {
    constructor() {
        this.permissions = new Set();
        this.companyId = null;
        this.loaded = false;
    }

    async init(companyId) {
        this.companyId = companyId;
        
        const { data, error } = await SB.client
            .rpc('get_user_permissions', { p_company_id: companyId });
        
        if (error) {
            console.error('Failed to load permissions:', error);
            this.permissions = new Set();
            return false;
        }
        
        this.permissions = new Set(data || []);
        this.loaded = true;
        return true;
    }

    can(permissionKey) {
        if (!this.loaded) {
            console.warn('[Permissions] Not initialized');
            return false;
        }
        return this.permissions.has(permissionKey);
    }

    canAny(...keys) {
        return keys.some(k => this.can(k));
    }

    canAll(...keys) {
        return keys.every(k => this.can(k));
    }

    all() {
        return Array.from(this.permissions);
    }

    async reload() {
        if (this.companyId) {
            await this.init(this.companyId);
        }
    }

    clear() {
        this.permissions = new Set();
        this.companyId = null;
        this.loaded = false;
    }
}

export const permissions = new PermissionService();

export const PERMISSIONS = {
    ITEMS_VIEW: 'items:view',
    ITEMS_CREATE: 'items:create',
    ITEMS_EDIT: 'items:edit',
    ITEMS_DELETE: 'items:delete',
    ITEMS_RESTORE: 'items:restore',
    ITEMS_HARD_DELETE: 'items:hard_delete',
    ITEMS_EXPORT: 'items:export',
    ITEMS_IMPORT: 'items:import',
    ORDERS_VIEW: 'orders:view',
    ORDERS_CREATE: 'orders:create',
    ORDERS_EDIT: 'orders:edit',
    ORDERS_DELETE: 'orders:delete',
    ORDERS_RESTORE: 'orders:restore',
    MEMBERS_VIEW: 'members:view',
    MEMBERS_INVITE: 'members:invite',
    MEMBERS_REMOVE: 'members:remove',
    MEMBERS_CHANGE_ROLE: 'members:change_role',
    COMPANY_VIEW_SETTINGS: 'company:view_settings',
    COMPANY_EDIT_SETTINGS: 'company:edit_settings',
    AUDIT_LOG_VIEW: 'audit_log:view',
    TRASH_VIEW: 'trash:view',
    SNAPSHOTS_VIEW: 'snapshots:view',
    SNAPSHOTS_CREATE: 'snapshots:create',
    SNAPSHOTS_RESTORE: 'snapshots:restore',
    SNAPSHOTS_DELETE: 'snapshots:delete',
    PLATFORM_VIEW_ALL_COMPANIES: 'platform:view_all_companies',
    PLATFORM_MANAGE_ROLES: 'platform:manage_roles',
    PLATFORM_VIEW_METRICS: 'platform:view_metrics'
};
```

## Usage Patterns

### Pattern 1: Conditional UI Elements

```javascript
import { permissions, PERMISSIONS } from './services/permissions.js';

function renderToolbar() {
    return `
        <div class="toolbar">
            ${permissions.can(PERMISSIONS.ITEMS_CREATE) ? 
                '<button id="btn-add">Add Item</button>' : ''}
            ${permissions.can(PERMISSIONS.ITEMS_DELETE) ? 
                '<button id="btn-delete">Delete</button>' : ''}
            ${permissions.can(PERMISSIONS.TRASH_VIEW) ? 
                '<button id="btn-trash">View Trash</button>' : ''}
        </div>
    `;
}
```

### Pattern 2: Protecting Actions

```javascript
async function deleteItem(itemId) {
    if (!permissions.can(PERMISSIONS.ITEMS_DELETE)) {
        showError('You do not have permission to delete items');
        return;
    }
    
    const { error } = await SB.client
        .rpc('soft_delete_item', { p_item_id: itemId });
    
    if (error) {
        showError('Failed to delete: ' + error.message);
        return;
    }
    
    showSuccess('Item moved to trash');
}
```

---

# Implementation Order

## Recommended Sequence

```
Week 1: Snapshots UI
├── Day 1-2: Verify/create inventory_snapshots table & RPCs
├── Day 3-4: Build Snapshots list page
└── Day 5: Build Create/Preview/Restore modals

Week 2: Metrics Dashboard
├── Day 1-2: Create materialized views & metric RPCs
├── Day 3-4: Build Company Dashboard view
└── Day 5: Build Platform Dashboard view (Super User)

Week 3: Security Testing
├── Day 1-2: Write & run RLS negative tests
├── Day 3: Write & run RBAC tests
├── Day 4: Write & run audit verification tests
└── Day 5: Manual testing checklist + fixes

Week 4: Role Engine
├── Day 1-2: Run Role Engine migration
├── Day 3: Implement frontend PermissionService
├── Day 4: Refactor existing UI to use permissions.can()
└── Day 5: Build Role Manager UI (Super User)
```

## Dependencies

```
┌─────────────────┐
│  Snapshots UI   │ ← No dependencies, can start immediately
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Metrics Dashboard│ ← Uses audit_log data (already exists)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Security Testing │ ← Tests all existing + new features
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Role Engine    │ ← Refactors permission checks
└─────────────────┘
```

---

# Consolidated Testing Checklist

## Unit Tests

### Snapshots
- [ ] `create_inventory_snapshot` captures all items correctly
- [ ] `create_inventory_snapshot` rejects non-admin users
- [ ] `restore_inventory_snapshot` in replace mode works
- [ ] `restore_inventory_snapshot` in merge mode works
- [ ] `restore_inventory_snapshot` creates pre-restore backup
- [ ] `restore_inventory_snapshot` rejects non-super-user
- [ ] `delete_inventory_snapshot` removes snapshot

### Metrics
- [ ] `get_company_metrics` returns correct counts
- [ ] `get_company_metrics` respects date range
- [ ] `get_company_metrics` rejects non-admin users
- [ ] `get_platform_metrics` returns all companies
- [ ] `get_platform_metrics` rejects non-super-user

### Role Engine
- [ ] `check_permission` returns correct boolean
- [ ] `get_user_permissions` returns correct set
- [ ] `set_role_permission` grants correctly
- [ ] `set_role_permission` revokes correctly
- [ ] `set_role_permission` logs to audit
- [ ] Super User permissions cannot be modified

## Integration Tests

- [ ] Full snapshot create → restore → verify flow
- [ ] Dashboard loads with real data
- [ ] Permission changes reflect in UI immediately
- [ ] Role Manager updates persist after refresh

## Security Tests

- [ ] All cross-company isolation tests pass
- [ ] All RBAC tests pass
- [ ] All hard delete prevention tests pass
- [ ] All audit verification tests pass

## Manual Verification

- [ ] Complete security checklist (Part 3)
- [ ] Test all user roles manually
- [ ] Verify production RLS policies match development

---

**End of Phase 1B Complete Specification**
