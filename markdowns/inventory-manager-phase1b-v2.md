# Inventory Manager: Phase 1B v2 — Complete Specification
## Snapshots UI, Metrics Dashboard, Security Validation & Role Engine

**Version:** 2.0  
**Date:** December 2024  
**Production URL:** `https://inventory.modulus-software.com`  
**Supabase Project:** Inventory Manager  
**Prerequisite:** Phase 1 (002_phase1_multitenancy.sql) complete

---

## Schema Alignment Notes

This spec is aligned with the existing Phase 1 implementation:

| Component | Existing Schema | Spec Approach |
|-----------|-----------------|---------------|
| Snapshots | `create_snapshot`, `restore_snapshot`, `get_snapshots` RPCs; `items_data`/`items_count` columns | Use existing RPCs, no changes |
| Role Engine | `role_configurations` with `permissions` JSONB; `is_super_user` flag | Extend existing table, define permission keys |
| Metrics | `action_metrics` table with daily aggregates | Query existing table, no materialized view |
| Members | `role` column + `is_super_user` boolean; no `deleted_at` | Use existing pattern |
| UI | Single `index.html` with modals | Add modals/sections, no new pages |

---

## Feature Registry Compliance

All Phase 1B features are registered in `products/inventory-manager/feature_registry.yaml`.
Pricing review is required for any medium/high support impact feature.

| Feature | feature_id | Tier Availability | Support Impact | Pricing Review |
|---------|------------|-------------------|----------------|----------------|
| Snapshots UI | `inventory.snapshots.ui` | Business, Enterprise | Medium | Required |
| Metrics Dashboard | `inventory.metrics.dashboard` | Professional, Business, Enterprise | Medium | Required |
| Security Testing Checklist | `inventory.security.checklist` | Enterprise (internal) | None | Not required |
| Role Engine | `inventory.auth.roles` | Business, Enterprise | High | Required |

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Part 1: Snapshots UI](#part-1-snapshots-ui)
3. [Part 2: Metrics Dashboard](#part-2-metrics-dashboard)
4. [Part 3: Security Testing](#part-3-security-testing)
5. [Part 4: Role Engine](#part-4-role-engine)
6. [Implementation Order](#implementation-order)
7. [Testing Checklist](#testing-checklist)

---

## Executive Summary

Phase 1B completes the multi-tenant SaaS transformation:

| Component | Purpose | Implementation |
|-----------|---------|----------------|
| **Snapshots UI** | Point-in-time backup & restore | Modal-based UI using existing RPCs |
| **Metrics Dashboard** | Activity visualization | Section/panel querying `action_metrics` |
| **Security Testing** | RLS validation | Test suite + manual checklist |
| **Role Engine** | Centralized permissions | Extend `role_configurations.permissions` JSONB |

---

# Part 1: Snapshots UI

## Overview

Feature: `inventory.snapshots.ui`  
Tier: Business, Enterprise  
Support impact: Medium (pricing review required)

Leverages existing snapshot infrastructure from Phase 1. No database changes required.

Scope in Phase 1B:
- View and preview snapshots only (read-only UI)
- No create/restore/delete actions in the UI (RPCs remain available for admins/SU via DB/CLI)

Tier gating:
- Show the Snapshots modal only for Business/Enterprise plans.

### Existing RPCs (from 002_phase1_multitenancy.sql)

| RPC | Parameters | Returns | Description |
|-----|------------|---------|-------------|
| `create_snapshot` | `p_company_id`, `p_name`, `p_description`, `p_type` | `JSON` | Creates snapshot (RPC only) |
| `restore_snapshot` | `p_snapshot_id`, `p_reason` | `JSON` | Restores snapshot (RPC only, preserves IDs) |
| `get_snapshots` | `p_company_id` | `TABLE` | Lists snapshots (summary only) |

### Existing Table Schema

```sql
-- inventory_snapshots (already exists)
CREATE TABLE inventory_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    snapshot_type TEXT DEFAULT 'manual',
    name TEXT,
    description TEXT,
    items_data JSONB NOT NULL,
    items_count INTEGER NOT NULL,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    restored_at TIMESTAMPTZ,
    restored_by UUID REFERENCES auth.users(id)
);
```

### Permission Requirements

| Action | Required Role |
|--------|---------------|
| View snapshots | Admin, Super User |

Note: Create/restore/delete remain RPC-only for Phase 1B and are not exposed in the UI.

## Frontend Implementation

### Snapshots Modal HTML

Add to `index.html`:

```html
<!-- Snapshots Modal -->
<div id="snapshots-modal" class="modal" style="display: none;">
    <div class="modal-content modal-large">
        <div class="modal-header">
            <h2>Inventory Snapshots</h2>
            <button class="modal-close" onclick="closeSnapshotsModal()">&times;</button>
        </div>
        
        <!-- Snapshots List -->
        <div id="snapshots-list" class="snapshots-list">
            <p class="loading">Loading snapshots...</p>
        </div>
        
        <!-- Snapshot Preview (hidden by default) -->
        <div id="snapshot-preview" class="snapshot-preview" style="display: none;">
            <div class="preview-header">
                <button class="btn-back" onclick="hideSnapshotPreview()">← Back</button>
                <h3 id="preview-title">Snapshot Preview</h3>
            </div>
            <div class="preview-meta" id="preview-meta"></div>
            <div class="preview-table-container">
                <table class="data-table" id="preview-table">
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>SKU</th>
                            <th>Quantity</th>
                            <th>Category ID</th>
                            <th>Location ID</th>
                        </tr>
                    </thead>
                    <tbody id="preview-table-body"></tbody>
                </table>
            </div>
            <div class="preview-actions" id="preview-actions"></div>
        </div>
    </div>
</div>
```

### Snapshots JavaScript

Add to your main JS file or create `snapshots.js`:

```javascript
// ============================================================================
// SNAPSHOTS MODULE
// ============================================================================

let currentSnapshots = [];
let selectedSnapshotId = null;

// ----------------------------------------------------------------------------
// Modal Controls
// ----------------------------------------------------------------------------

function openSnapshotsModal() {
    // Check permission
    if (!can(PERMISSIONS.SNAPSHOTS_VIEW)) {
        toast('You do not have permission to view snapshots');
        return;
    }
    
    document.getElementById('snapshots-modal').style.display = 'flex';
    loadSnapshots();
}

function closeSnapshotsModal() {
    document.getElementById('snapshots-modal').style.display = 'none';
    hideSnapshotPreview();
}

// ----------------------------------------------------------------------------
// Load Snapshots
// ----------------------------------------------------------------------------

async function loadSnapshots() {
    const listContainer = document.getElementById('snapshots-list');
    listContainer.innerHTML = '<p class="loading">Loading snapshots...</p>';
    
    try {
        if (!SB.client || !SB.companyId) throw new Error('No company selected');
        
        const { data, error } = await SB.client.rpc('get_snapshots', {
            p_company_id: SB.companyId
        });
        
        if (error) throw error;
        
        currentSnapshots = data || [];
        renderSnapshotsList();
        
    } catch (err) {
        console.error('Failed to load snapshots:', err);
        listContainer.innerHTML = '<p class="error">Failed to load snapshots</p>';
    }
}

function renderSnapshotsList() {
    const listContainer = document.getElementById('snapshots-list');
    
    if (currentSnapshots.length === 0) {
        listContainer.innerHTML = `
            <div class="empty-state">
                <p>No snapshots yet.</p>
                <p>Create a snapshot to backup your current inventory state.</p>
            </div>
        `;
        return;
    }
    listContainer.innerHTML = currentSnapshots.map(snapshot => `
        <div class="snapshot-card" data-id="${snapshot.id}">
            <div class="snapshot-info">
                <div class="snapshot-name">${escapeHtml(snapshot.name || 'Unnamed Snapshot')}</div>
                <div class="snapshot-meta">
                    ${snapshot.items_count} items • 
                    ${formatDate(snapshot.created_at)}
                    ${snapshot.restored_at ? `<span class="restored-badge">Restored ${formatDate(snapshot.restored_at)}</span>` : ''}
                </div>
                ${snapshot.description ? `<div class="snapshot-description">${escapeHtml(snapshot.description)}</div>` : ''}
            </div>
            <div class="snapshot-actions">
                <button class="btn" onclick="previewSnapshot('${snapshot.id}')">
                    Preview
                </button>
            </div>
        </div>
    `).join('');
}

// ----------------------------------------------------------------------------
// Preview Snapshot
// ----------------------------------------------------------------------------

async function previewSnapshot(snapshotId) {
    const summary = currentSnapshots.find(s => s.id === snapshotId);
    if (!summary) return;
    
    // Hide list, show preview
    document.getElementById('snapshots-list').style.display = 'none';
    
    const previewContainer = document.getElementById('snapshot-preview');
    previewContainer.style.display = 'block';
    
    selectedSnapshotId = snapshotId;
    
    try {
        const { data, error } = await SB.client
            .from('inventory_snapshots')
            .select('items_data,name,description,items_count,created_at')
            .eq('id', snapshotId)
            .single();
        
        if (error) throw error;
        
        const snapshot = { ...summary, ...data };
        
        // Set header
        document.getElementById('preview-title').textContent = snapshot.name || 'Snapshot Preview';
        document.getElementById('preview-meta').innerHTML = `
            <span>${snapshot.items_count} items</span> • 
            <span>Created ${formatDate(snapshot.created_at)}</span>
            ${snapshot.description ? `<br><em>${escapeHtml(snapshot.description)}</em>` : ''}
        `;
        
        // Render items table
        const items = Array.isArray(snapshot.items_data) ? snapshot.items_data : [];
        const tbody = document.getElementById('preview-table-body');
        
        if (items.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5">No items in this snapshot</td></tr>';
        } else {
            tbody.innerHTML = items.slice(0, 100).map(item => `
                <tr>
                    <td>${escapeHtml(item.name || '')}</td>
                    <td>${escapeHtml(item.sku || '')}</td>
                    <td>${item.quantity || 0}</td>
                    <td>${escapeHtml(item.category_id || '')}</td>
                    <td>${escapeHtml(item.location_id || '')}</td>
                </tr>
            `).join('');
            
            if (items.length > 100) {
                tbody.innerHTML += `<tr><td colspan="5" class="text-muted">Showing first 100 of ${items.length} items</td></tr>`;
            }
        }
    } catch (err) {
        console.error('Failed to load snapshot detail:', err);
        document.getElementById('preview-table-body').innerHTML = '<tr><td colspan="5">Failed to load snapshot items</td></tr>';
    }
    
    const actionsContainer = document.getElementById('preview-actions');
    actionsContainer.innerHTML = `<p class="text-muted">Read-only in Phase 1B.</p>`;
}

function hideSnapshotPreview() {
    document.getElementById('snapshot-preview').style.display = 'none';
    document.getElementById('snapshots-list').style.display = 'block';
    selectedSnapshotId = null;
}

// ----------------------------------------------------------------------------
// Utility Functions
// ----------------------------------------------------------------------------

function formatDate(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
```

### Snapshots CSS

Add to your stylesheet:

```css
/* Snapshots Modal Styles */

.modal-large {
    max-width: 900px;
    max-height: 85vh;
    overflow: hidden;
    display: flex;
    flex-direction: column;
}

.modal-large .modal-header {
    flex-shrink: 0;
}

.snapshots-list {
    flex: 1;
    overflow-y: auto;
    padding: 16px 24px;
}

.snapshot-card {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 16px;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    margin-bottom: 12px;
    background: #fff;
}

.snapshot-card:hover {
    border-color: #1976d2;
}

.snapshot-info {
    flex: 1;
}

.snapshot-name {
    font-weight: 600;
    font-size: 15px;
    margin-bottom: 4px;
}

.snapshot-meta {
    font-size: 13px;
    color: #666;
}

.snapshot-description {
    font-size: 13px;
    color: #888;
    margin-top: 4px;
}

.snapshot-actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
}

.restored-badge {
    background: #e3f2fd;
    color: #1976d2;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    margin-left: 8px;
}

/* Preview */
.snapshot-preview {
    padding: 16px 24px;
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.preview-header {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 12px;
}

.preview-header h3 {
    margin: 0;
}

.btn-back {
    background: none;
    border: none;
    color: #1976d2;
    cursor: pointer;
    font-size: 14px;
}

.preview-meta {
    font-size: 13px;
    color: #666;
    margin-bottom: 16px;
}

.preview-table-container {
    flex: 1;
    overflow: auto;
    border: 1px solid #e0e0e0;
    border-radius: 4px;
}

.preview-actions {
    padding-top: 16px;
    text-align: right;
}

.empty-state {
    text-align: center;
    padding: 48px;
    color: #666;
}

.text-muted {
    color: #888;
}
```

### Menu Integration

Add a button to open snapshots (in your nav/toolbar):

```javascript
// In your navigation or settings menu
function renderAdminMenu() {
    const menu = document.getElementById('admin-menu');
    
    if (can(PERMISSIONS.SNAPSHOTS_VIEW)) {
        menu.innerHTML += `
            <button onclick="openSnapshotsModal()">
                📸 Snapshots
            </button>
        `;
    }
}
```

---

# Part 2: Metrics Dashboard

## Overview

Feature: `inventory.metrics.dashboard`  
Tier: Professional, Business, Enterprise  
Support impact: Medium (pricing review required)

Uses existing `action_metrics` table. No new tables; adds RPCs for aggregation.

Tier gating:
- Company dashboard: Professional/Business/Enterprise plans.
- Platform dashboard: Super User only (Enterprise).

### Existing `action_metrics` Schema

```sql
CREATE TABLE action_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID REFERENCES companies(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id),
    metric_date DATE NOT NULL DEFAULT CURRENT_DATE,
    action_type TEXT NOT NULL,  -- 'delete', 'bulk_delete', 'update', 'restore', 'rollback'
    table_name TEXT NOT NULL,
    action_count INTEGER NOT NULL DEFAULT 1,
    records_affected INTEGER NOT NULL DEFAULT 1,
    quantity_removed INTEGER DEFAULT 0,
    quantity_added INTEGER DEFAULT 0,
    UNIQUE (company_id, user_id, metric_date, action_type, table_name)
);
```

### New RPCs Needed

```sql
-- ============================================================================
-- METRICS DASHBOARD RPCs
-- ============================================================================

-- Get company metrics for dashboard
CREATE OR REPLACE FUNCTION get_company_dashboard_metrics(
    p_company_id UUID,
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_result JSONB;
BEGIN
    v_user_id := auth.uid();
    
    -- Check if user is admin or super user
    IF public.is_super_user() THEN
        v_is_admin := true;
    ELSE
        SELECT (role = 'admin') INTO v_is_admin
        FROM company_members
        WHERE company_id = p_company_id AND user_id = v_user_id;
    END IF;
    
    IF NOT v_is_admin THEN
        RAISE EXCEPTION 'Permission denied: admin role required';
    END IF;
    
    SELECT jsonb_build_object(
        -- Current state counts
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
                WHERE company_id = p_company_id
            ),
            'snapshot_count', (
                SELECT COUNT(*) FROM inventory_snapshots 
                WHERE company_id = p_company_id
            )
        ),
        
        -- Activity totals from action_metrics
        'activity', (
            SELECT jsonb_build_object(
                'total_updates', COALESCE(SUM(CASE WHEN action_type = 'update' THEN action_count ELSE 0 END), 0),
                'total_deletes', COALESCE(SUM(CASE WHEN action_type IN ('delete', 'bulk_delete') THEN action_count ELSE 0 END), 0),
                'total_restores', COALESCE(SUM(CASE WHEN action_type = 'restore' THEN action_count ELSE 0 END), 0),
                'total_rollbacks', COALESCE(SUM(CASE WHEN action_type = 'rollback' THEN action_count ELSE 0 END), 0),
                'records_affected', COALESCE(SUM(records_affected), 0),
                'quantity_removed', COALESCE(SUM(quantity_removed), 0),
                'quantity_added', COALESCE(SUM(quantity_added), 0)
            )
            FROM action_metrics
            WHERE company_id = p_company_id
              AND metric_date >= CURRENT_DATE - p_days
        ),
        
        -- Daily breakdown for charts
        'daily', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'date', metric_date,
                    'action_type', action_type,
                    'action_count', SUM(action_count),
                    'records_affected', SUM(records_affected)
                )
                ORDER BY metric_date DESC
            ), '[]'::jsonb)
            FROM action_metrics
            WHERE company_id = p_company_id
              AND metric_date >= CURRENT_DATE - p_days
            GROUP BY metric_date, action_type
        ),
        
        -- Top users by activity
        'top_users', (
            SELECT COALESCE(jsonb_agg(u), '[]'::jsonb)
            FROM (
                SELECT 
                    am.user_id,
                    p.email,
                    SUM(am.action_count) AS total_actions
                FROM action_metrics am
                JOIN profiles p ON p.user_id = am.user_id
                WHERE am.company_id = p_company_id
                  AND am.metric_date >= CURRENT_DATE - p_days
                GROUP BY am.user_id, p.email
                ORDER BY total_actions DESC
                LIMIT 5
            ) u
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

-- Get platform metrics (Super User only)
CREATE OR REPLACE FUNCTION get_platform_dashboard_metrics(
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_result JSONB;
BEGIN
    v_user_id := auth.uid();
    
    -- Check super user
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied: Super User required';
    END IF;
    
    SELECT jsonb_build_object(
        -- Platform totals
        'platform', jsonb_build_object(
            'total_companies', (SELECT COUNT(*) FROM companies),
            'total_users', (SELECT COUNT(DISTINCT user_id) FROM company_members),
            'total_items', (SELECT COUNT(*) FROM inventory_items WHERE deleted_at IS NULL),
            'total_orders', (SELECT COUNT(*) FROM orders WHERE deleted_at IS NULL)
        ),
        
        -- Activity summary
        'activity', jsonb_build_object(
            'total_actions', (
                SELECT COALESCE(SUM(action_count), 0) FROM action_metrics 
                WHERE metric_date >= CURRENT_DATE - p_days
            ),
            'active_companies', (
                SELECT COUNT(DISTINCT company_id) FROM action_metrics 
                WHERE metric_date >= CURRENT_DATE - p_days
            ),
            'active_users', (
                SELECT COUNT(DISTINCT user_id) FROM action_metrics 
                WHERE metric_date >= CURRENT_DATE - p_days
            )
        ),
        
        -- Per-company breakdown
        'companies', (
            SELECT COALESCE(jsonb_agg(c), '[]'::jsonb)
            FROM (
                SELECT 
                    co.id,
                    co.name,
                    (SELECT COUNT(*) FROM company_members cm WHERE cm.company_id = co.id) AS member_count,
                    (SELECT COUNT(*) FROM inventory_items ii WHERE ii.company_id = co.id AND ii.deleted_at IS NULL) AS item_count,
                    COALESCE((
                        SELECT SUM(action_count) FROM action_metrics am 
                        WHERE am.company_id = co.id AND am.metric_date >= CURRENT_DATE - p_days
                    ), 0) AS recent_actions
                FROM companies co
                ORDER BY recent_actions DESC
                LIMIT 20
            ) c
        ),
        
        -- Daily platform activity
        'daily', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'date', metric_date,
                    'total_actions', total_actions,
                    'active_companies', active_companies
                )
                ORDER BY metric_date DESC
            ), '[]'::jsonb)
            FROM (
                SELECT 
                    metric_date,
                    SUM(action_count) AS total_actions,
                    COUNT(DISTINCT company_id) AS active_companies
                FROM action_metrics
                WHERE metric_date >= CURRENT_DATE - p_days
                GROUP BY metric_date
            ) d
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
```

## Frontend Implementation

### Dashboard Section HTML

Add to `index.html`:

```html
<!-- Metrics Dashboard Modal -->
<div id="metrics-modal" class="modal" style="display: none;">
    <div class="modal-content modal-large">
        <div class="modal-header">
            <h2 id="metrics-title">Dashboard</h2>
            <button class="modal-close" onclick="closeMetricsModal()">&times;</button>
        </div>
        
        <div class="metrics-toolbar">
            <select id="metrics-date-range" onchange="loadMetrics()">
                <option value="7">Last 7 days</option>
                <option value="30" selected>Last 30 days</option>
                <option value="90">Last 90 days</option>
            </select>
            
            <!-- Super User: View selector -->
            <select id="metrics-view-selector" style="display: none;" onchange="loadMetrics()">
                <option value="company">Company View</option>
                <option value="platform">Platform View</option>
            </select>
        </div>
        
        <div class="metrics-content" id="metrics-content">
            <p class="loading">Loading metrics...</p>
        </div>
    </div>
</div>
```

### Dashboard JavaScript

```javascript
// ============================================================================
// METRICS DASHBOARD MODULE
// ============================================================================

let metricsChart = null;

function openMetricsModal() {
    // Check permission
    if (!can(PERMISSIONS.METRICS_VIEW) && !can(PERMISSIONS.PLATFORM_VIEW_METRICS)) {
        toast('You do not have permission to view metrics');
        return;
    }
    
    document.getElementById('metrics-modal').style.display = 'flex';
    
    // Show view selector for super users
    if (can(PERMISSIONS.PLATFORM_VIEW_METRICS)) {
        document.getElementById('metrics-view-selector').style.display = 'inline-block';
    }
    
    loadMetrics();
}

function closeMetricsModal() {
    document.getElementById('metrics-modal').style.display = 'none';
    if (metricsChart) {
        metricsChart.destroy();
        metricsChart = null;
    }
}

async function loadMetrics() {
    const container = document.getElementById('metrics-content');
    container.innerHTML = '<p class="loading">Loading metrics...</p>';
    
    const days = parseInt(document.getElementById('metrics-date-range').value);
    const viewMode = document.getElementById('metrics-view-selector').value;
    
    try {
        let data;
        
        if (can(PERMISSIONS.PLATFORM_VIEW_METRICS) && viewMode === 'platform') {
            document.getElementById('metrics-title').textContent = 'Platform Dashboard';
            const response = await SB.client.rpc('get_platform_dashboard_metrics', { p_days: days });
            if (response.error) throw response.error;
            data = response.data;
            renderPlatformMetrics(data, days);
        } else {
            document.getElementById('metrics-title').textContent = 'Company Dashboard';
            const response = await SB.client.rpc('get_company_dashboard_metrics', {
                p_company_id: SB.companyId,
                p_days: days
            });
            if (response.error) throw response.error;
            data = response.data;
            renderCompanyMetrics(data, days);
        }
        
    } catch (err) {
        console.error('Failed to load metrics:', err);
        container.innerHTML = '<p class="error">Failed to load metrics</p>';
    }
}

function renderCompanyMetrics(data, days) {
    const container = document.getElementById('metrics-content');
    
    const current = data.current || {};
    const activity = data.activity || {};
    const topUsers = data.top_users || [];
    
    container.innerHTML = `
        <!-- Current State Cards -->
        <div class="metrics-section">
            <h3>Current State</h3>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-value">${(current.total_items || 0).toLocaleString()}</div>
                    <div class="metric-label">Total Items</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${(current.total_quantity || 0).toLocaleString()}</div>
                    <div class="metric-label">Total Quantity</div>
                </div>
                <div class="metric-card ${current.low_stock_count > 0 ? 'metric-warning' : ''}">
                    <div class="metric-value">${current.low_stock_count || 0}</div>
                    <div class="metric-label">Low Stock</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${current.active_members || 0}</div>
                    <div class="metric-label">Team Members</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${current.snapshot_count || 0}</div>
                    <div class="metric-label">Snapshots</div>
                </div>
            </div>
        </div>
        
        <!-- Activity Summary -->
        <div class="metrics-section">
            <h3>Activity (Last ${days} Days)</h3>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-value">${activity.total_updates || 0}</div>
                    <div class="metric-label">Updates</div>
                </div>
                <div class="metric-card metric-negative">
                    <div class="metric-value">${activity.total_deletes || 0}</div>
                    <div class="metric-label">Deletes</div>
                </div>
                <div class="metric-card metric-positive">
                    <div class="metric-value">${activity.total_restores || 0}</div>
                    <div class="metric-label">Restores</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${activity.total_rollbacks || 0}</div>
                    <div class="metric-label">Rollbacks</div>
                </div>
            </div>
            <div class="metrics-summary">
                <span>${(activity.records_affected || 0).toLocaleString()} records affected</span> •
                <span class="text-negative">-${(activity.quantity_removed || 0).toLocaleString()} qty</span> •
                <span class="text-positive">+${(activity.quantity_added || 0).toLocaleString()} qty</span>
            </div>
        </div>
        
        <!-- Activity Chart -->
        <div class="metrics-section">
            <h3>Activity Over Time</h3>
            <div class="chart-container">
                <canvas id="metrics-chart"></canvas>
            </div>
        </div>
        
        <!-- Top Users -->
        <div class="metrics-section">
            <h3>Top Contributors</h3>
            <div class="ranking-list">
                ${topUsers.length === 0 ? '<p class="text-muted">No activity in this period</p>' : 
                    topUsers.map((user, idx) => `
                        <div class="ranking-item">
                            <span class="ranking-position">${idx + 1}</span>
                            <span class="ranking-name">${escapeHtml(user.email || 'Unknown')}</span>
                            <span class="ranking-value">${user.total_actions} actions</span>
                        </div>
                    `).join('')
                }
            </div>
        </div>
    `;
    
    renderActivityChart(data.daily || [], 'metrics-chart');
}

function renderPlatformMetrics(data, days) {
    const container = document.getElementById('metrics-content');
    
    const platform = data.platform || {};
    const activity = data.activity || {};
    const companies = data.companies || [];
    
    container.innerHTML = `
        <!-- Platform Overview -->
        <div class="metrics-section">
            <h3>Platform Overview</h3>
            <div class="metrics-grid">
                <div class="metric-card metric-primary">
                    <div class="metric-value">${platform.total_companies || 0}</div>
                    <div class="metric-label">Companies</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${platform.total_users || 0}</div>
                    <div class="metric-label">Users</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${(platform.total_items || 0).toLocaleString()}</div>
                    <div class="metric-label">Items</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${(platform.total_orders || 0).toLocaleString()}</div>
                    <div class="metric-label">Orders</div>
                </div>
            </div>
        </div>
        
        <!-- Activity Summary -->
        <div class="metrics-section">
            <h3>Activity (Last ${days} Days)</h3>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-value">${(activity.total_actions || 0).toLocaleString()}</div>
                    <div class="metric-label">Total Actions</div>
                </div>
                <div class="metric-card metric-positive">
                    <div class="metric-value">${activity.active_companies || 0}</div>
                    <div class="metric-label">Active Companies</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${activity.active_users || 0}</div>
                    <div class="metric-label">Active Users</div>
                </div>
            </div>
        </div>
        
        <!-- Activity Chart -->
        <div class="metrics-section">
            <h3>Platform Activity</h3>
            <div class="chart-container">
                <canvas id="metrics-chart"></canvas>
            </div>
        </div>
        
        <!-- Top Companies -->
        <div class="metrics-section">
            <h3>Most Active Companies</h3>
            <div class="ranking-list">
                ${companies.length === 0 ? '<p class="text-muted">No companies found</p>' :
                    companies.map((company, idx) => `
                        <div class="ranking-item">
                            <span class="ranking-position">${idx + 1}</span>
                            <div class="ranking-details">
                                <span class="ranking-name">${escapeHtml(company.name)}</span>
                                <span class="ranking-meta">${company.member_count} members • ${company.item_count} items</span>
                            </div>
                            <span class="ranking-value">${company.recent_actions} actions</span>
                        </div>
                    `).join('')
                }
            </div>
        </div>
    `;
    
    renderPlatformChart(data.daily || [], 'metrics-chart');
}

function renderActivityChart(dailyData, canvasId) {
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    
    if (metricsChart) {
        metricsChart.destroy();
    }
    
    // Aggregate by date
    const dateMap = new Map();
    dailyData.forEach(item => {
        const date = item.date;
        if (!dateMap.has(date)) {
            dateMap.set(date, { date, total: 0 });
        }
        dateMap.get(date).total += item.action_count || 0;
    });
    
    const sorted = Array.from(dateMap.values()).sort((a, b) => 
        new Date(a.date) - new Date(b.date)
    );
    
    metricsChart = new Chart(ctx, {
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
                y: { beginAtZero: true, ticks: { precision: 0 } }
            },
            plugins: {
                legend: { display: false }
            }
        }
    });
}

function renderPlatformChart(dailyData, canvasId) {
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    
    if (metricsChart) {
        metricsChart.destroy();
    }
    
    const sorted = dailyData.sort((a, b) => new Date(a.date) - new Date(b.date));
    
    metricsChart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: sorted.map(d => d.date),
            datasets: [
                {
                    label: 'Total Actions',
                    data: sorted.map(d => d.total_actions || 0),
                    borderColor: '#1976d2',
                    fill: false,
                    yAxisID: 'y'
                },
                {
                    label: 'Active Companies',
                    data: sorted.map(d => d.active_companies || 0),
                    borderColor: '#43a047',
                    fill: false,
                    yAxisID: 'y1'
                }
            ]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                y: { type: 'linear', position: 'left', beginAtZero: true },
                y1: { type: 'linear', position: 'right', beginAtZero: true, grid: { drawOnChartArea: false } }
            }
        }
    });
}
```

### Dashboard CSS

```css
/* Metrics Dashboard Styles */

.metrics-toolbar {
    padding: 12px 24px;
    border-bottom: 1px solid #e0e0e0;
    display: flex;
    gap: 12px;
}

.metrics-toolbar select {
    padding: 8px 12px;
    border: 1px solid #ddd;
    border-radius: 4px;
    font-size: 14px;
}

.metrics-content {
    padding: 24px;
    overflow-y: auto;
    max-height: calc(85vh - 140px);
}

.metrics-section {
    margin-bottom: 32px;
}

.metrics-section h3 {
    font-size: 14px;
    font-weight: 600;
    color: #333;
    margin-bottom: 12px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 12px;
}

.metric-card {
    background: #fff;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 16px;
    text-align: center;
}

.metric-value {
    font-size: 28px;
    font-weight: 700;
    color: #333;
}

.metric-label {
    font-size: 12px;
    color: #666;
    margin-top: 4px;
}

.metric-card.metric-primary {
    border-left: 4px solid #1976d2;
    background: #e3f2fd;
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

.metrics-summary {
    margin-top: 12px;
    font-size: 13px;
    color: #666;
}

.text-positive { color: #43a047; }
.text-negative { color: #e53935; }

.chart-container {
    background: #fff;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 16px;
    height: 250px;
}

.ranking-list {
    background: #fff;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
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

.ranking-item:nth-child(1) .ranking-position { background: #ffd700; }
.ranking-item:nth-child(2) .ranking-position { background: #c0c0c0; }
.ranking-item:nth-child(3) .ranking-position { background: #cd7f32; color: #fff; }

.ranking-name {
    flex: 1;
    font-weight: 500;
}

.ranking-details {
    flex: 1;
    display: flex;
    flex-direction: column;
}

.ranking-meta {
    font-size: 12px;
    color: #666;
}

.ranking-value {
    font-size: 13px;
    color: #666;
}
```

### Chart.js Dependency

Add to your HTML `<head>`:

```html
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
```

---

# Part 3: Security Testing

Feature: `inventory.security.checklist`  
Tier: Enterprise (internal)  
Support impact: None

## Test Environment Setup

```javascript
// test/security-tests.js
// Run these tests against your Supabase instance

const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

// Admin client (bypasses RLS)
const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

// Test users - create these in your test environment
const TEST_USERS = {
    SUPER_USER: { email: 'test-super@test.com', password: 'Test123!' },
    ADMIN_A: { email: 'test-admin-a@test.com', password: 'Test123!', company: 'Company A' },
    MEMBER_A: { email: 'test-member-a@test.com', password: 'Test123!', company: 'Company A' },
    VIEWER_A: { email: 'test-viewer-a@test.com', password: 'Test123!', company: 'Company A' },
    ADMIN_B: { email: 'test-admin-b@test.com', password: 'Test123!', company: 'Company B' }
};

async function getAuthenticatedClient(user) {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data, error } = await client.auth.signInWithPassword({
        email: user.email,
        password: user.password
    });
    if (error) throw error;
    return client;
}
```

## RLS Negative Tests

### Cross-Company Isolation

```javascript
describe('Cross-Company Data Isolation', () => {
    let clientA, clientB;
    let companyAId, companyBId;
    let testItemId;

    beforeAll(async () => {
        clientA = await getAuthenticatedClient(TEST_USERS.ADMIN_A);
        clientB = await getAuthenticatedClient(TEST_USERS.ADMIN_B);
        
        // Get company IDs
        const { data: memA } = await clientA.from('company_members').select('company_id').single();
        const { data: memB } = await clientB.from('company_members').select('company_id').single();
        companyAId = memA.company_id;
        companyBId = memB.company_id;
        
        // Create test item in Company A
        const { data: item } = await clientA
            .from('inventory_items')
            .insert({ company_id: companyAId, name: 'Test Item A', quantity: 10 })
            .select()
            .single();
        testItemId = item.id;
    });

    test('Company B cannot SELECT items from Company A', async () => {
        const { data } = await clientB
            .from('inventory_items')
            .select('*')
            .eq('id', testItemId);
        
        expect(data).toHaveLength(0);
    });

    test('Company B cannot UPDATE items in Company A', async () => {
        const { data, error } = await clientB
            .from('inventory_items')
            .update({ name: 'Hacked!' })
            .eq('id', testItemId)
            .select();
        
        // Should return empty array (no rows matched due to RLS)
        expect(data).toHaveLength(0);
    });

    test('Company B cannot INSERT into Company A', async () => {
        const { error } = await clientB
            .from('inventory_items')
            .insert({ company_id: companyAId, name: 'Malicious', quantity: 1 });
        
        expect(error).not.toBeNull();
    });

    test('Company B cannot view Company A audit_log', async () => {
        const { data } = await clientB
            .from('audit_log')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });

    test('Company B cannot view Company A snapshots', async () => {
        const { data } = await clientB
            .from('inventory_snapshots')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });

    test('Company B cannot view Company A members', async () => {
        const { data } = await clientB
            .from('company_members')
            .select('*')
            .eq('company_id', companyAId);
        
        expect(data).toHaveLength(0);
    });
});
```

### Role-Based Access Control

```javascript
describe('RBAC Enforcement', () => {
    let superClient, adminClient, memberClient, viewerClient;
    let companyId, testItemId;

    beforeAll(async () => {
        superClient = await getAuthenticatedClient(TEST_USERS.SUPER_USER);
        adminClient = await getAuthenticatedClient(TEST_USERS.ADMIN_A);
        memberClient = await getAuthenticatedClient(TEST_USERS.MEMBER_A);
        viewerClient = await getAuthenticatedClient(TEST_USERS.VIEWER_A);
        
        const { data } = await adminClient.from('company_members').select('company_id').single();
        companyId = data.company_id;
    });

    describe('Viewer Role', () => {
        test('CAN view items', async () => {
            const { data, error } = await viewerClient
                .from('inventory_items')
                .select('*')
                .eq('company_id', companyId);
            
            expect(error).toBeNull();
        });

        test('CANNOT create items', async () => {
            const { error } = await viewerClient
                .from('inventory_items')
                .insert({ company_id: companyId, name: 'Viewer Item', quantity: 1 });
            
            expect(error).not.toBeNull();
        });

        test('CANNOT update items', async () => {
            const { data } = await viewerClient
                .from('inventory_items')
                .update({ quantity: 999 })
                .eq('company_id', companyId)
                .select();
            
            expect(data).toHaveLength(0);
        });

        test('CANNOT access audit_log', async () => {
            const { data } = await viewerClient
                .from('audit_log')
                .select('*')
                .eq('company_id', companyId);
            
            expect(data).toHaveLength(0);
        });
    });

    describe('Member Role', () => {
        test('CAN create items', async () => {
            const { data, error } = await memberClient
                .from('inventory_items')
                .insert({ company_id: companyId, name: 'Member Item', quantity: 5 })
                .select()
                .single();
            
            expect(error).toBeNull();
            expect(data).not.toBeNull();
        });

        test('CAN update items', async () => {
            // Create then update
            const { data: item } = await memberClient
                .from('inventory_items')
                .insert({ company_id: companyId, name: 'Update Test', quantity: 1 })
                .select()
                .single();
            
            const { error } = await memberClient
                .from('inventory_items')
                .update({ quantity: 10 })
                .eq('id', item.id);
            
            expect(error).toBeNull();
        });

        test('CANNOT soft delete items', async () => {
            const { data: item } = await adminClient
                .from('inventory_items')
                .insert({ company_id: companyId, name: 'Delete Test', quantity: 1 })
                .select()
                .single();
            
            const { error } = await memberClient.rpc('soft_delete_item', { p_item_id: item.id });
            
            expect(error).not.toBeNull();
        });

        test('CANNOT invite members', async () => {
            const { error } = await memberClient.rpc('invite_user', {
                p_company_id: companyId,
                p_email: 'newuser@test.com',
                p_role: 'member'
            });
            
            expect(error).not.toBeNull();
        });
    });

    describe('Admin Role', () => {
        test('CAN soft delete items', async () => {
            const { data: item } = await adminClient
                .from('inventory_items')
                .insert({ company_id: companyId, name: 'Admin Delete', quantity: 1 })
                .select()
                .single();
            
            const { error } = await adminClient.rpc('soft_delete_item', { p_item_id: item.id });
            
            expect(error).toBeNull();
        });

        test('CAN restore items', async () => {
            // Get a deleted item
            const { data: items } = await adminClient
                .from('inventory_items')
                .select('id')
                .eq('company_id', companyId)
                .not('deleted_at', 'is', null)
                .limit(1);
            
            if (items.length > 0) {
                const { error } = await adminClient.rpc('restore_item', { p_item_id: items[0].id });
                expect(error).toBeNull();
            }
        });

        test('CAN invite members', async () => {
            const { data, error } = await adminClient.rpc('invite_user', {
                p_company_id: companyId,
                p_email: 'invited-admin@test.com',
                p_role: 'member'
            });
            
            expect(error).toBeNull();
        });

        test('CAN access audit_log', async () => {
            const { data, error } = await adminClient
                .from('audit_log')
                .select('*')
                .eq('company_id', companyId);
            
            expect(error).toBeNull();
        });

        test('CAN create snapshots', async () => {
            const { data, error } = await adminClient.rpc('create_snapshot', {
                p_company_id: companyId,
                p_name: 'Admin Test Snapshot'
            });
            
            expect(error).toBeNull();
            expect(data && data.success).toBe(true);
        });

        test('CANNOT restore snapshots', async () => {
            // Get a snapshot
            const { data: snapshots } = await adminClient
                .from('inventory_snapshots')
                .select('id')
                .eq('company_id', companyId)
                .limit(1);
            
            if (snapshots.length > 0) {
                const { error } = await adminClient.rpc('restore_snapshot', {
                    p_snapshot_id: snapshots[0].id
                });
                expect(error).not.toBeNull();
            }
        });
    });

    describe('Super User', () => {
        test('CAN restore snapshots', async () => {
            // Create a snapshot first
            const { data: snapshotData, error: snapshotError } = await superClient.rpc('create_snapshot', {
                p_company_id: companyId,
                p_name: 'Super User Test'
            });
            expect(snapshotError).toBeNull();
            const snapshotId = snapshotData && snapshotData.snapshot_id;
            expect(snapshotId).toBeTruthy();
            
            const { data, error } = await superClient.rpc('restore_snapshot', {
                p_snapshot_id: snapshotId
            });
            
            expect(error).toBeNull();
            expect(data.items_restored).toBeDefined();
        });

        test('CAN access platform metrics', async () => {
            const { data, error } = await superClient.rpc('get_platform_dashboard_metrics', {
                p_days: 30
            });
            
            expect(error).toBeNull();
            expect(data.platform).toBeDefined();
        });
    });
});
```

### Hard Delete Prevention

```javascript
describe('Hard Delete Prevention', () => {
    let adminClient;
    let companyId, testItemId;

    beforeAll(async () => {
        adminClient = await getAuthenticatedClient(TEST_USERS.ADMIN_A);
        
        const { data } = await adminClient.from('company_members').select('company_id').single();
        companyId = data.company_id;
        
        const { data: item } = await adminClient
            .from('inventory_items')
            .insert({ company_id: companyId, name: 'Hard Delete Test', quantity: 1 })
            .select()
            .single();
        testItemId = item.id;
    });

    test('Direct DELETE on inventory_items is blocked', async () => {
        const { error } = await adminClient
            .from('inventory_items')
            .delete()
            .eq('id', testItemId);
        
        // Should error - no DELETE permission
        expect(error).not.toBeNull();
    });

    test('Direct DELETE on orders is blocked', async () => {
        const { data: authData } = await adminClient.auth.getUser();
        const userId = authData && authData.user ? authData.user.id : null;
        const { data: order } = await adminClient
            .from('orders')
            .insert({
                company_id: companyId,
                created_by: userId,
                to_email: 'test@example.com',
                subject: 'Hard Delete Test',
                line_items: []
            })
            .select()
            .single();
        
        const { error } = await adminClient
            .from('orders')
            .delete()
            .eq('id', order.id);
        
        expect(error).not.toBeNull();
    });

    test('Soft delete RPC works correctly', async () => {
        const { error } = await adminClient.rpc('soft_delete_item', { p_item_id: testItemId });
        
        expect(error).toBeNull();
        
        // Verify item is soft deleted
        const { data } = await adminClient
            .from('inventory_items')
            .select('deleted_at')
            .eq('id', testItemId)
            .single();
        
        expect(data.deleted_at).not.toBeNull();
    });
});
```

## Manual Testing Checklist

```markdown
## Pre-Launch Security Verification

### Cross-Company Isolation
- [ ] User A cannot see Company B items in inventory list
- [ ] User A cannot see Company B orders
- [ ] User A cannot see Company B team members
- [ ] User A cannot see Company B audit logs
- [ ] User A cannot see Company B snapshots
- [ ] Direct API call with wrong company_id returns empty/error

### Role Permissions
- [ ] Viewer: Can view items, cannot create/edit/delete
- [ ] Member: Can create/edit items, cannot delete/manage users
- [ ] Admin: Can delete/restore, can invite/manage users (except super user)
- [ ] Admin: Cannot promote anyone to super user
- [ ] Admin: Cannot restore snapshots
- [ ] Super User: Full access including snapshot restore

### Soft Delete Verification
- [ ] Deleted items show in trash modal for Admin/SU
- [ ] Deleted items hidden from main inventory list
- [ ] Restore moves item back to active inventory
- [ ] Hard delete (direct DELETE) is blocked

### Snapshot Verification
- [ ] Snapshot captures all current items correctly
- [ ] Preview shows accurate item data
- [ ] Restore replaces inventory (preserves IDs)
- [ ] Only Super User can restore
- [ ] Restore creates pre-restore backup

### Audit Log Verification
- [ ] Item create is logged
- [ ] Item update is logged
- [ ] Item soft delete is logged
- [ ] Item restore is logged
- [ ] Snapshot create is logged
- [ ] Snapshot restore is logged

### Session Security
- [ ] Expired token returns 401
- [ ] Invalid token returns 401
- [ ] Unauthenticated requests blocked

### Edge Cases
- [ ] Empty company (no items) works
- [ ] User with no membership gets appropriate error
- [ ] Very large snapshot (1000+ items) works
```

---

# Part 4: Role Engine

## Overview

Feature: `inventory.auth.roles`  
Tier: Business, Enterprise  
Support impact: High (pricing review required)

Extends existing `role_configurations` table rather than creating new tables.

Tier gating:
- Role Manager UI: Business/Enterprise only.
- Only Super User can modify role_configurations.

### Existing Schema

```sql
-- role_configurations (already exists)
CREATE TABLE role_configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name TEXT NOT NULL UNIQUE,  -- 'admin', 'member', 'viewer'
    permissions JSONB NOT NULL DEFAULT '{}',
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    updated_by UUID REFERENCES auth.users(id)
);
```

### Design Decision: Super User

**Super User is NOT a row in `role_configurations`.**

Instead:
- `company_members.is_super_user = true` grants all permissions
- Permission checks: `IF is_super_user THEN RETURN true`
- This matches your existing pattern

## Permission Schema

### Permission Keys (JSONB structure)

```javascript
// role_configurations.permissions JSONB structure
{
    // Inventory
    "items:view": true,
    "items:create": true,
    "items:edit": true,
    "items:delete": true,
    "items:restore": true,
    "items:export": true,
    "items:import": true,
    
    // Orders
    "orders:view": true,
    "orders:create": true,
    "orders:edit": true,
    "orders:delete": true,
    "orders:restore": true,
    
    // Members
    "members:view": true,
    "members:invite": true,
    "members:remove": true,
    "members:change_role": true,
    
    // Company
    "company:view_settings": true,
    "company:edit_settings": true,
    
    // Audit & Recovery
    "audit_log:view": true,
    "metrics:view": true,
    "snapshots:view": true
    // Note: create/delete/restore are RPC-only in Phase 1B and not exposed via UI permissions
}
```

### Default Permission Sets

```sql
-- Seed/update role_configurations with permission sets

-- Admin permissions
UPDATE role_configurations
SET permissions = '{
    "items:view": true,
    "items:create": true,
    "items:edit": true,
    "items:delete": true,
    "items:restore": true,
    "items:export": true,
    "items:import": true,
    "orders:view": true,
    "orders:create": true,
    "orders:edit": true,
    "orders:delete": true,
    "orders:restore": true,
    "members:view": true,
    "members:invite": true,
    "members:remove": true,
    "members:change_role": true,
    "company:view_settings": true,
    "company:edit_settings": true,
    "audit_log:view": true,
    "metrics:view": true,
    "snapshots:view": true
}'::jsonb,
    updated_at = now()
WHERE role_name = 'admin';

-- Member permissions
UPDATE role_configurations
SET permissions = '{
    "items:view": true,
    "items:create": true,
    "items:edit": true,
    "items:export": true,
    "orders:view": true,
    "orders:create": true,
    "orders:edit": true,
    "members:view": true
}'::jsonb,
    updated_at = now()
WHERE role_name = 'member';

-- Viewer permissions
UPDATE role_configurations
SET permissions = '{
    "items:view": true,
    "items:export": true,
    "orders:view": true,
    "members:view": true
}'::jsonb,
    updated_at = now()
WHERE role_name = 'viewer';
```

## Permission Check RPC

```sql
-- Check if current user has a specific permission
CREATE OR REPLACE FUNCTION check_permission(
    p_company_id UUID,
    p_permission_key TEXT
) RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_role TEXT;
    v_has_permission BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    
    IF v_user_id IS NULL THEN
        RETURN false;
    END IF;
    
    -- Super user has all permissions
    IF public.is_super_user() THEN
        RETURN true;
    END IF;
    
    -- Get user's role for the company
    SELECT role 
    INTO v_role
    FROM company_members
    WHERE company_id = p_company_id AND user_id = v_user_id;
    
    IF v_role IS NULL THEN
        RETURN false;
    END IF;
    
    -- Check role_configurations for permission
    SELECT (rc.permissions->>p_permission_key)::boolean
    INTO v_has_permission
    FROM role_configurations rc
    WHERE rc.role_name = v_role;
    
    RETURN COALESCE(v_has_permission, false);
END;
$$;

-- Get all permissions for current user
CREATE OR REPLACE FUNCTION get_user_permissions(
    p_company_id UUID
) RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_role TEXT;
    v_permissions JSONB;
BEGIN
    v_user_id := auth.uid();
    
    IF v_user_id IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;
    
    -- Super user gets all permissions
    IF public.is_super_user() THEN
        RETURN '{
            "items:view": true, "items:create": true, "items:edit": true,
            "items:delete": true, "items:restore": true, "items:export": true, "items:import": true,
            "orders:view": true, "orders:create": true, "orders:edit": true,
            "orders:delete": true, "orders:restore": true,
            "members:view": true, "members:invite": true, "members:remove": true, "members:change_role": true,
            "company:view_settings": true, "company:edit_settings": true,
            "audit_log:view": true, "metrics:view": true,
            "snapshots:view": true,
            "platform:view_all_companies": true, "platform:manage_roles": true, "platform:view_metrics": true
        }'::jsonb;
    END IF;
    
    -- Get user's role for the company
    SELECT role 
    INTO v_role
    FROM company_members
    WHERE company_id = p_company_id AND user_id = v_user_id;
    
    IF v_role IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;
    
    -- Return role permissions
    SELECT rc.permissions
    INTO v_permissions
    FROM role_configurations rc
    WHERE rc.role_name = v_role;
    
    RETURN COALESCE(v_permissions, '{}'::jsonb);
END;
$$;
```

## Frontend Permission Service

```javascript
// ============================================================================
// PERMISSIONS MODULE
// ============================================================================

let userPermissions = {};
let permissionsLoaded = false;

// Permission key constants
const PERMISSIONS = {
    // Inventory
    ITEMS_VIEW: 'items:view',
    ITEMS_CREATE: 'items:create',
    ITEMS_EDIT: 'items:edit',
    ITEMS_DELETE: 'items:delete',
    ITEMS_RESTORE: 'items:restore',
    ITEMS_EXPORT: 'items:export',
    ITEMS_IMPORT: 'items:import',
    
    // Orders
    ORDERS_VIEW: 'orders:view',
    ORDERS_CREATE: 'orders:create',
    ORDERS_EDIT: 'orders:edit',
    ORDERS_DELETE: 'orders:delete',
    ORDERS_RESTORE: 'orders:restore',
    
    // Members
    MEMBERS_VIEW: 'members:view',
    MEMBERS_INVITE: 'members:invite',
    MEMBERS_REMOVE: 'members:remove',
    MEMBERS_CHANGE_ROLE: 'members:change_role',
    
    // Company
    COMPANY_VIEW_SETTINGS: 'company:view_settings',
    COMPANY_EDIT_SETTINGS: 'company:edit_settings',
    
    // Audit
    AUDIT_LOG_VIEW: 'audit_log:view',
    METRICS_VIEW: 'metrics:view',
    
    // Snapshots
    SNAPSHOTS_VIEW: 'snapshots:view',
    
    // Platform (Super User only)
    PLATFORM_VIEW_ALL: 'platform:view_all_companies',
    PLATFORM_MANAGE_ROLES: 'platform:manage_roles',
    PLATFORM_VIEW_METRICS: 'platform:view_metrics'
};

// Load permissions on app init
async function loadPermissions() {
    if (!SB.companyId) {
        console.warn('Cannot load permissions: no company context');
        return;
    }
    
    try {
        const { data, error } = await SB.client.rpc('get_user_permissions', {
            p_company_id: SB.companyId
        });
        
        if (error) throw error;
        
        userPermissions = data || {};
        permissionsLoaded = true;
        
        console.log('[Permissions] Loaded:', Object.keys(userPermissions).filter(k => userPermissions[k]).length, 'permissions');
        
    } catch (err) {
        console.error('Failed to load permissions:', err);
        userPermissions = {};
    }
}

// Check single permission
function can(permissionKey) {
    if (!permissionsLoaded) {
        console.warn('[Permissions] Checking before loaded');
        return false;
    }
    return userPermissions[permissionKey] === true;
}

// Check if user has ANY of the permissions
function canAny(...permissionKeys) {
    return permissionKeys.some(key => can(key));
}

// Check if user has ALL of the permissions
function canAll(...permissionKeys) {
    return permissionKeys.every(key => can(key));
}

// Reload permissions (after role change)
async function reloadPermissions() {
    await loadPermissions();
}

// Clear permissions (on logout)
function clearPermissions() {
    userPermissions = {};
    permissionsLoaded = false;
}
```

## Usage Examples

### Conditional UI Elements

```javascript
// Toolbar buttons
function renderInventoryToolbar() {
    let html = '<div class="toolbar">';
    
    if (can(PERMISSIONS.ITEMS_CREATE)) {
        html += '<button onclick="showAddItemModal()">+ Add Item</button>';
    }
    
    if (can(PERMISSIONS.ITEMS_DELETE)) {
        html += '<button onclick="deleteSelectedItems()">Delete</button>';
    }
    
    if (can(PERMISSIONS.ITEMS_EXPORT)) {
        html += '<button onclick="exportItems()">Export CSV</button>';
    }
    
    if (can(PERMISSIONS.SNAPSHOTS_VIEW)) {
        html += '<button onclick="openSnapshotsModal()">Snapshots</button>';
    }
    
    if (can(PERMISSIONS.AUDIT_LOG_VIEW)) {
        html += '<button onclick="openAuditLog()">Audit Log</button>';
    }

    if (can(PERMISSIONS.METRICS_VIEW) || can(PERMISSIONS.PLATFORM_VIEW_METRICS)) {
        html += '<button onclick="openMetricsModal()">Metrics</button>';
    }
    
    html += '</div>';
    return html;
}

// Row actions
function renderItemActions(item) {
    let html = '';
    
    if (can(PERMISSIONS.ITEMS_EDIT)) {
        html += `<button onclick="editItem('${item.id}')">Edit</button>`;
    }
    
    if (can(PERMISSIONS.ITEMS_DELETE)) {
        html += `<button onclick="deleteItem('${item.id}')">Delete</button>`;
    }
    
    return html || '<span class="text-muted">View only</span>';
}
```

### Protecting Actions

```javascript
async function deleteItem(itemId) {
    if (!can(PERMISSIONS.ITEMS_DELETE)) {
        toast('You do not have permission to delete items');
        return;
    }
    
    // Proceed with delete
    const { error } = await SB.client.rpc('soft_delete_item', { p_item_id: itemId });
    // ...
}

async function openMetrics() {
    if (!can(PERMISSIONS.METRICS_VIEW) && !can(PERMISSIONS.PLATFORM_VIEW_METRICS)) {
        toast('You do not have permission to view metrics');
        return;
    }
    
    openMetricsModal();
}
```

## Super User Role Manager UI

Only Super Users can modify role permissions.

### HTML

```html
<!-- Role Manager Modal (Super User only) -->
<div id="role-manager-modal" class="modal" style="display: none;">
    <div class="modal-content modal-large">
        <div class="modal-header">
            <h2>Role Permission Manager</h2>
            <button class="modal-close" onclick="closeRoleManagerModal()">&times;</button>
        </div>
        
        <p class="modal-description">
            Configure which permissions each role has access to.
            Super User permissions cannot be modified.
        </p>
        
        <div class="role-matrix-container">
            <table class="role-matrix" id="role-matrix">
                <thead>
                    <tr>
                        <th>Permission</th>
                        <th>Admin</th>
                        <th>Member</th>
                        <th>Viewer</th>
                    </tr>
                </thead>
                <tbody id="role-matrix-body">
                    <!-- Populated by JS -->
                </tbody>
            </table>
        </div>
        
        <div class="modal-footer">
            <button class="btn-secondary" onclick="closeRoleManagerModal()">Close</button>
            <button class="btn-primary" onclick="saveRolePermissions()">Save Changes</button>
        </div>
    </div>
</div>
```

### JavaScript

```javascript
// ============================================================================
// ROLE MANAGER MODULE (Super User only)
// ============================================================================

let roleConfigs = {};
let pendingChanges = {};

const PERMISSION_CATEGORIES = {
    'Inventory': [
        { key: 'items:view', label: 'View Items' },
        { key: 'items:create', label: 'Create Items' },
        { key: 'items:edit', label: 'Edit Items' },
        { key: 'items:delete', label: 'Delete Items' },
        { key: 'items:restore', label: 'Restore Items' },
        { key: 'items:export', label: 'Export Items' },
        { key: 'items:import', label: 'Import Items' }
    ],
    'Orders': [
        { key: 'orders:view', label: 'View Orders' },
        { key: 'orders:create', label: 'Create Orders' },
        { key: 'orders:edit', label: 'Edit Orders' },
        { key: 'orders:delete', label: 'Delete Orders' },
        { key: 'orders:restore', label: 'Restore Orders' }
    ],
    'Members': [
        { key: 'members:view', label: 'View Members' },
        { key: 'members:invite', label: 'Invite Members' },
        { key: 'members:remove', label: 'Remove Members' },
        { key: 'members:change_role', label: 'Change Roles' }
    ],
    'Company': [
        { key: 'company:view_settings', label: 'View Settings' },
        { key: 'company:edit_settings', label: 'Edit Settings' }
    ],
    'Audit & Metrics': [
        { key: 'audit_log:view', label: 'View Audit Log' },
        { key: 'metrics:view', label: 'View Metrics' },
        { key: 'snapshots:view', label: 'View Snapshots' }
    ]
};

function openRoleManagerModal() {
    if (!isSuperUser()) {
        toast('Only Super Users can manage roles');
        return;
    }
    
    document.getElementById('role-manager-modal').style.display = 'flex';
    loadRoleConfigurations();
}

function closeRoleManagerModal() {
    document.getElementById('role-manager-modal').style.display = 'none';
    pendingChanges = {};
}

async function loadRoleConfigurations() {
    try {
        const { data, error } = await SB.client
            .from('role_configurations')
            .select('*');
        
        if (error) throw error;
        
        roleConfigs = {};
        data.forEach(rc => {
            roleConfigs[rc.role_name] = rc.permissions || {};
        });
        
        renderRoleMatrix();
        
    } catch (err) {
        console.error('Failed to load role configurations:', err);
        toast('Failed to load role configurations');
    }
}

function renderRoleMatrix() {
    const tbody = document.getElementById('role-matrix-body');
    let html = '';
    
    for (const [category, permissions] of Object.entries(PERMISSION_CATEGORIES)) {
        // Category header
        html += `
            <tr class="category-row">
                <td colspan="4">${category}</td>
            </tr>
        `;
        
        // Permission rows
        for (const perm of permissions) {
            html += `
                <tr class="permission-row">
                    <td class="permission-label">${perm.label}</td>
                    <td class="role-cell">
                        <input type="checkbox" 
                            data-role="admin" 
                            data-permission="${perm.key}"
                            ${roleConfigs.admin?.[perm.key] ? 'checked' : ''}
                            onchange="handlePermissionChange(this)">
                    </td>
                    <td class="role-cell">
                        <input type="checkbox" 
                            data-role="member" 
                            data-permission="${perm.key}"
                            ${roleConfigs.member?.[perm.key] ? 'checked' : ''}
                            onchange="handlePermissionChange(this)">
                    </td>
                    <td class="role-cell">
                        <input type="checkbox" 
                            data-role="viewer" 
                            data-permission="${perm.key}"
                            ${roleConfigs.viewer?.[perm.key] ? 'checked' : ''}
                            onchange="handlePermissionChange(this)">
                    </td>
                </tr>
            `;
        }
    }
    
    tbody.innerHTML = html;
}

function handlePermissionChange(checkbox) {
    const role = checkbox.dataset.role;
    const permission = checkbox.dataset.permission;
    const granted = checkbox.checked;
    
    if (!pendingChanges[role]) {
        pendingChanges[role] = { ...roleConfigs[role] };
    }
    
    pendingChanges[role][permission] = granted;
}

async function saveRolePermissions() {
    if (Object.keys(pendingChanges).length === 0) {
        toast('No changes to save');
        return;
    }
    
    try {
        for (const [role, permissions] of Object.entries(pendingChanges)) {
            const { error } = await SB.client
                .from('role_configurations')
                .update({ 
                    permissions,
                    updated_at: new Date().toISOString(),
                    updated_by: SB.user ? SB.user.id : null
                })
                .eq('role_name', role);
            
            if (error) throw error;
        }
        
        toast('Role permissions saved');
        pendingChanges = {};
        
        // Reload current user's permissions in case they changed
        await reloadPermissions();
        
    } catch (err) {
        console.error('Failed to save role permissions:', err);
        toast('Failed to save: ' + err.message);
    }
}
```

### CSS

```css
/* Role Manager Styles */

.role-matrix-container {
    max-height: 500px;
    overflow-y: auto;
    margin: 16px 0;
}

.role-matrix {
    width: 100%;
    border-collapse: collapse;
}

.role-matrix th,
.role-matrix td {
    padding: 10px 12px;
    text-align: left;
    border-bottom: 1px solid #e0e0e0;
}

.role-matrix th {
    background: #f5f5f5;
    font-weight: 600;
    position: sticky;
    top: 0;
}

.role-matrix th:not(:first-child) {
    text-align: center;
    width: 100px;
}

.category-row td {
    background: #e3f2fd;
    font-weight: 600;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: #1976d2;
}

.permission-label {
    padding-left: 24px !important;
}

.role-cell {
    text-align: center !important;
}

.role-cell input[type="checkbox"] {
    width: 18px;
    height: 18px;
    cursor: pointer;
}

.modal-description {
    padding: 0 24px;
    color: #666;
    font-size: 14px;
}

.modal-footer {
    padding: 16px 24px;
    border-top: 1px solid #e0e0e0;
    display: flex;
    justify-content: flex-end;
    gap: 12px;
}
```

---

# Implementation Order

## Recommended Sequence

```
Week 1: Snapshots UI
├── Day 1: Add modal HTML/CSS to index.html
├── Day 2: Implement snapshots.js (list, preview)
├── Day 3: Add snapshot detail fetch + preview table
└── Day 4: Test with existing RPCs

Week 2: Metrics Dashboard
├── Day 1: Add metrics RPCs to database
├── Day 2: Add modal HTML/CSS
├── Day 3: Implement dashboard.js (company view)
├── Day 4: Implement platform view (Super User)
└── Day 5: Add Chart.js integration

Week 3: Security Testing
├── Day 1-2: Set up test environment
├── Day 3: Run RLS negative tests
├── Day 4: Run RBAC tests
└── Day 5: Manual testing checklist

Week 4: Role Engine
├── Day 1: Seed role_configurations with permissions JSONB
├── Day 2: Add check_permission & get_user_permissions RPCs
├── Day 3: Implement permissions.js frontend module
├── Day 4: Refactor existing UI to use can() checks
└── Day 5: Build Role Manager modal (Super User)
```

---

# Testing Checklist

## Unit Tests

### Snapshots
- [ ] `create_snapshot` captures items correctly
- [ ] `restore_snapshot` preserves item IDs
- [ ] `restore_snapshot` creates backup first
- [ ] Only admin+ can create snapshots
- [ ] Only super user can restore snapshots

### Metrics
- [ ] `get_company_dashboard_metrics` returns correct counts
- [ ] `get_platform_dashboard_metrics` returns all companies
- [ ] Date range filtering works correctly
- [ ] Only admin+ can access company metrics
- [ ] Only super user can access platform metrics

### Role Engine
- [ ] `check_permission` returns correct boolean
- [ ] `get_user_permissions` returns complete permission set
- [ ] Super user gets all permissions
- [ ] Permission changes persist after save
- [ ] Audit log captures permission changes

## Security Tests

- [ ] Cross-company isolation (all tables)
- [ ] Role permission boundaries
- [ ] Hard delete prevention
- [ ] Audit log completeness

## Manual Tests

- [ ] Complete security checklist
- [ ] Test all user roles end-to-end
- [ ] Verify production RLS matches dev

---

**End of Phase 1B v2 Specification**
