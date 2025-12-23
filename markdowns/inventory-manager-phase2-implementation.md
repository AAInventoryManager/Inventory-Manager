# Inventory Manager: Phase 2 Implementation Guide
## Competitive Features: Reporting, Barcode Scanning, CSV, Purchase Orders, Vendors

**Version:** 1.0  
**Date:** December 2024  
**Prerequisite:** Phase 1 must be completed first  
**Production URL:** `https://inventory.modulus-software.com`

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Feature Overview](#feature-overview)
3. [Feature 1: Reporting Dashboard](#feature-1-reporting-dashboard)
4. [Feature 2: Barcode Scanning](#feature-2-barcode-scanning)
5. [Feature 3: CSV Import/Export](#feature-3-csv-importexport)
6. [Feature 4: Purchase Orders](#feature-4-purchase-orders)
7. [Feature 5: Vendor Management](#feature-5-vendor-management)
8. [Feature 6: Low Stock Email Alerts](#feature-6-low-stock-email-alerts)
9. [Feature 7: Stock Transfers](#feature-7-stock-transfers)
10. [Database Migration](#database-migration)
11. [Frontend Implementation](#frontend-implementation)
12. [Testing Checklist](#testing-checklist)

---

## Executive Summary

Phase 2 adds competitive features that differentiate Inventory Manager from basic spreadsheet solutions:

| Feature | Business Value | Effort |
|---------|---------------|--------|
| **Reporting Dashboard** | Actionable insights, not just data | Medium |
| **Barcode Scanning** | 10x faster receiving/picking | Medium |
| **CSV Import/Export** | Easy migration, bulk updates | Low |
| **Purchase Orders** | Track what's coming in | High |
| **Vendor Management** | Know who to order from | Low |
| **Low Stock Alerts** | Proactive notifications | Low |
| **Stock Transfers** | Multi-location support | Medium |

---

## Feature Overview

### Target User Stories

1. **As a warehouse manager**, I want to see a dashboard showing low stock items, inventory value, and recent activity so I can make informed decisions.

2. **As a receiving clerk**, I want to scan barcodes with my phone to quickly add items to inventory.

3. **As an admin**, I want to import our existing inventory from a CSV file so we can migrate from spreadsheets.

4. **As a purchaser**, I want to create purchase orders and track what's on order vs. what's in stock.

5. **As an owner**, I want to receive email alerts when items are running low so I never run out.

6. **As an operations manager**, I want to transfer stock between locations and track inventory by location.

---

## Feature 1: Reporting Dashboard

### Overview

A visual dashboard showing key inventory metrics at a glance.

### Dashboard Components

```
┌─────────────────────────────────────────────────────────────────────┐
│  📊 INVENTORY DASHBOARD                              [Last 30 Days] │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │     847      │  │   $124,500   │  │      12      │  │    3     │ │
│  │  Total Items │  │ Total Value  │  │  Low Stock   │  │ Out of   │ │
│  │              │  │              │  │   ⚠️         │  │ Stock 🔴 │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘ │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  ⚠️ ITEMS NEEDING ATTENTION                                         │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Item Name          │ Current │ Reorder Point │ Status          ││
│  ├─────────────────────────────────────────────────────────────────┤│
│  │ Widget A           │    2    │      10       │ 🔴 CRITICAL     ││
│  │ Gadget B           │    0    │       5       │ 🔴 OUT OF STOCK ││
│  │ Thing C            │    8    │      15       │ 🟡 LOW          ││
│  │ Sprocket D         │   12    │      20       │ 🟡 LOW          ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  📈 INVENTORY MOVEMENT (Last 30 Days)                               │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                                                                 ││
│  │  Received: +523 units    Sold/Used: -312 units    Net: +211    ││
│  │                                                                 ││
│  │  ████████████████████                                          ││
│  │  ██████████████                                                ││
│  │  ████████                                                      ││
│  │  Dec 1    Dec 7    Dec 14    Dec 21    Dec 28                  ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  📋 TOP ITEMS BY VALUE                │  🏷️ CATEGORY BREAKDOWN      │
│  ┌────────────────────────────────┐   │  ┌────────────────────────┐ │
│  │ 1. Industrial Motor  $12,500  │   │  │ Electronics    45%    │ │
│  │ 2. Premium Filter    $8,200   │   │  │ Hardware       30%    │ │
│  │ 3. Control Unit      $6,800   │   │  │ Consumables    15%    │ │
│  │ 4. Sensor Array      $5,100   │   │  │ Other          10%    │ │
│  │ 5. Power Supply      $4,300   │   │  └────────────────────────┘ │
│  └────────────────────────────────┘   │                             │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  🔍 DEAD STOCK (No movement in 90+ days)                            │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Item Name          │ Qty │ Value   │ Last Activity │ Action    ││
│  ├─────────────────────────────────────────────────────────────────┤│
│  │ Legacy Part X      │  45 │ $2,250  │ 142 days ago  │ [Review]  ││
│  │ Old Model Y        │  23 │ $1,150  │ 98 days ago   │ [Review]  ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

### SQL Views for Dashboard

```sql
-- ============================================================================
-- REPORTING DASHBOARD VIEWS AND FUNCTIONS
-- ============================================================================

-- Dashboard summary stats
CREATE OR REPLACE FUNCTION public.get_dashboard_stats(p_company_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_result JSON;
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;
    
    SELECT json_build_object(
        'total_items', (
            SELECT COUNT(*) FROM inventory_items 
            WHERE company_id = p_company_id AND deleted_at IS NULL
        ),
        'total_quantity', (
            SELECT COALESCE(SUM(quantity), 0) FROM inventory_items 
            WHERE company_id = p_company_id AND deleted_at IS NULL
        ),
        'total_value', (
            SELECT COALESCE(SUM(quantity * COALESCE(unit_cost, 0)), 0) 
            FROM inventory_items 
            WHERE company_id = p_company_id AND deleted_at IS NULL
        ),
        'low_stock_count', (
            SELECT COUNT(*) FROM inventory_items 
            WHERE company_id = p_company_id 
            AND deleted_at IS NULL
            AND low_stock_qty IS NOT NULL 
            AND quantity <= low_stock_qty
            AND quantity > 0
        ),
        'out_of_stock_count', (
            SELECT COUNT(*) FROM inventory_items 
            WHERE company_id = p_company_id 
            AND deleted_at IS NULL
            AND quantity = 0
        ),
        'items_with_value', (
            SELECT COUNT(*) FROM inventory_items 
            WHERE company_id = p_company_id 
            AND deleted_at IS NULL
            AND unit_cost IS NOT NULL
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

-- Low stock items list
CREATE OR REPLACE FUNCTION public.get_low_stock_items(p_company_id UUID)
RETURNS TABLE (
    id UUID,
    name TEXT,
    sku TEXT,
    quantity INTEGER,
    low_stock_qty INTEGER,
    reorder_point INTEGER,
    unit_cost DECIMAL,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.sku,
        i.quantity,
        i.low_stock_qty,
        i.reorder_point,
        i.unit_cost,
        CASE 
            WHEN i.quantity = 0 THEN 'out_of_stock'
            WHEN i.quantity <= COALESCE(i.low_stock_qty, i.reorder_point, 0) * 0.5 THEN 'critical'
            WHEN i.quantity <= COALESCE(i.low_stock_qty, i.reorder_point, 0) THEN 'low'
            ELSE 'ok'
        END as status
    FROM inventory_items i
    WHERE i.company_id = p_company_id
    AND i.deleted_at IS NULL
    AND (
        i.quantity = 0
        OR (i.low_stock_qty IS NOT NULL AND i.quantity <= i.low_stock_qty)
        OR (i.reorder_point IS NOT NULL AND i.quantity <= i.reorder_point)
    )
    ORDER BY 
        CASE WHEN i.quantity = 0 THEN 0 ELSE 1 END,
        i.quantity ASC
    LIMIT 20;
END;
$$;

-- Inventory movement summary (last N days)
CREATE OR REPLACE FUNCTION public.get_inventory_movement(
    p_company_id UUID,
    p_days INTEGER DEFAULT 30
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;
    
    RETURN json_build_object(
        'period_days', p_days,
        'received', (
            SELECT COALESCE(SUM(quantity_change), 0) 
            FROM inventory_transactions 
            WHERE company_id = p_company_id 
            AND created_at >= CURRENT_DATE - p_days
            AND quantity_change > 0
        ),
        'removed', (
            SELECT COALESCE(ABS(SUM(quantity_change)), 0) 
            FROM inventory_transactions 
            WHERE company_id = p_company_id 
            AND created_at >= CURRENT_DATE - p_days
            AND quantity_change < 0
        ),
        'daily_breakdown', (
            SELECT json_agg(row_to_json(t) ORDER BY t.day)
            FROM (
                SELECT 
                    DATE(created_at) as day,
                    SUM(CASE WHEN quantity_change > 0 THEN quantity_change ELSE 0 END) as received,
                    SUM(CASE WHEN quantity_change < 0 THEN ABS(quantity_change) ELSE 0 END) as removed
                FROM inventory_transactions
                WHERE company_id = p_company_id
                AND created_at >= CURRENT_DATE - p_days
                GROUP BY DATE(created_at)
            ) t
        )
    );
END;
$$;

-- Top items by value
CREATE OR REPLACE FUNCTION public.get_top_items_by_value(
    p_company_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    quantity INTEGER,
    unit_cost DECIMAL,
    total_value DECIMAL
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.quantity,
        i.unit_cost,
        (i.quantity * COALESCE(i.unit_cost, 0)) as total_value
    FROM inventory_items i
    WHERE i.company_id = p_company_id
    AND i.deleted_at IS NULL
    AND i.unit_cost IS NOT NULL
    ORDER BY (i.quantity * i.unit_cost) DESC
    LIMIT p_limit;
END;
$$;

-- Dead stock (no movement in N days)
CREATE OR REPLACE FUNCTION public.get_dead_stock(
    p_company_id UUID,
    p_days INTEGER DEFAULT 90
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    quantity INTEGER,
    unit_cost DECIMAL,
    total_value DECIMAL,
    last_activity TIMESTAMPTZ,
    days_since_activity INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.quantity,
        i.unit_cost,
        (i.quantity * COALESCE(i.unit_cost, 0)) as total_value,
        (
            SELECT MAX(t.created_at) 
            FROM inventory_transactions t 
            WHERE t.item_id = i.id
        ) as last_activity,
        COALESCE(
            EXTRACT(DAY FROM (now() - (
                SELECT MAX(t.created_at) 
                FROM inventory_transactions t 
                WHERE t.item_id = i.id
            )))::integer,
            EXTRACT(DAY FROM (now() - i.created_at))::integer
        ) as days_since_activity
    FROM inventory_items i
    WHERE i.company_id = p_company_id
    AND i.deleted_at IS NULL
    AND i.quantity > 0
    AND (
        NOT EXISTS (
            SELECT 1 FROM inventory_transactions t 
            WHERE t.item_id = i.id 
            AND t.created_at > now() - (p_days || ' days')::interval
        )
    )
    ORDER BY days_since_activity DESC
    LIMIT 20;
END;
$$;

-- Category breakdown
CREATE OR REPLACE FUNCTION public.get_category_breakdown(p_company_id UUID)
RETURNS TABLE (
    category_id UUID,
    category_name TEXT,
    item_count BIGINT,
    total_quantity BIGINT,
    total_value DECIMAL,
    percentage DECIMAL
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_total_value DECIMAL;
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    -- Get total value first
    SELECT COALESCE(SUM(quantity * COALESCE(unit_cost, 0)), 1)
    INTO v_total_value
    FROM inventory_items
    WHERE company_id = p_company_id AND deleted_at IS NULL;
    
    RETURN QUERY
    SELECT 
        c.id,
        COALESCE(c.name, 'Uncategorized'),
        COUNT(i.id),
        COALESCE(SUM(i.quantity), 0)::bigint,
        COALESCE(SUM(i.quantity * COALESCE(i.unit_cost, 0)), 0),
        ROUND((COALESCE(SUM(i.quantity * COALESCE(i.unit_cost, 0)), 0) / v_total_value * 100)::numeric, 1)
    FROM inventory_items i
    LEFT JOIN inventory_categories c ON c.id = i.category_id
    WHERE i.company_id = p_company_id
    AND i.deleted_at IS NULL
    GROUP BY c.id, c.name
    ORDER BY SUM(i.quantity * COALESCE(i.unit_cost, 0)) DESC NULLS LAST;
END;
$$;
```

### Frontend: Dashboard Component

```javascript
async function loadDashboard() {
    const companyId = SB.currentCompanyId;
    
    // Load all dashboard data in parallel
    const [stats, lowStock, movement, topItems, deadStock, categories] = await Promise.all([
        SB.client.rpc('get_dashboard_stats', { p_company_id: companyId }),
        SB.client.rpc('get_low_stock_items', { p_company_id: companyId }),
        SB.client.rpc('get_inventory_movement', { p_company_id: companyId, p_days: 30 }),
        SB.client.rpc('get_top_items_by_value', { p_company_id: companyId, p_limit: 5 }),
        SB.client.rpc('get_dead_stock', { p_company_id: companyId, p_days: 90 }),
        SB.client.rpc('get_category_breakdown', { p_company_id: companyId })
    ]);
    
    renderDashboard({
        stats: stats.data,
        lowStock: lowStock.data,
        movement: movement.data,
        topItems: topItems.data,
        deadStock: deadStock.data,
        categories: categories.data
    });
}

function renderDashboard(data) {
    const container = document.getElementById('dashboardContent');
    
    container.innerHTML = `
        <div class="dashboard-grid">
            <!-- Summary Cards -->
            <div class="stat-cards">
                <div class="stat-card">
                    <div class="stat-value">${data.stats.total_items}</div>
                    <div class="stat-label">Total Items</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">$${formatNumber(data.stats.total_value)}</div>
                    <div class="stat-label">Total Value</div>
                </div>
                <div class="stat-card warning">
                    <div class="stat-value">${data.stats.low_stock_count}</div>
                    <div class="stat-label">Low Stock ⚠️</div>
                </div>
                <div class="stat-card danger">
                    <div class="stat-value">${data.stats.out_of_stock_count}</div>
                    <div class="stat-label">Out of Stock 🔴</div>
                </div>
            </div>
            
            <!-- Low Stock Table -->
            <div class="dashboard-section">
                <h3>⚠️ Items Needing Attention</h3>
                <table class="dashboard-table">
                    <thead>
                        <tr>
                            <th>Item</th>
                            <th>SKU</th>
                            <th>Current</th>
                            <th>Reorder At</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${(data.lowStock || []).map(item => `
                            <tr class="status-${item.status}">
                                <td>${item.name}</td>
                                <td>${item.sku || '-'}</td>
                                <td>${item.quantity}</td>
                                <td>${item.low_stock_qty || item.reorder_point || '-'}</td>
                                <td><span class="status-badge ${item.status}">${formatStatus(item.status)}</span></td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            </div>
            
            <!-- Movement Summary -->
            <div class="dashboard-section">
                <h3>📈 Inventory Movement (Last 30 Days)</h3>
                <div class="movement-summary">
                    <div class="movement-stat positive">
                        <span class="label">Received</span>
                        <span class="value">+${data.movement.received} units</span>
                    </div>
                    <div class="movement-stat negative">
                        <span class="label">Removed</span>
                        <span class="value">-${data.movement.removed} units</span>
                    </div>
                    <div class="movement-stat ${data.movement.received - data.movement.removed >= 0 ? 'positive' : 'negative'}">
                        <span class="label">Net</span>
                        <span class="value">${data.movement.received - data.movement.removed} units</span>
                    </div>
                </div>
                <canvas id="movementChart" height="200"></canvas>
            </div>
            
            <!-- Top Items & Categories -->
            <div class="dashboard-row">
                <div class="dashboard-section half">
                    <h3>📋 Top Items by Value</h3>
                    <table class="dashboard-table compact">
                        <tbody>
                            ${(data.topItems || []).map((item, i) => `
                                <tr>
                                    <td>${i + 1}.</td>
                                    <td>${item.name}</td>
                                    <td class="right">$${formatNumber(item.total_value)}</td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
                <div class="dashboard-section half">
                    <h3>🏷️ Category Breakdown</h3>
                    <table class="dashboard-table compact">
                        <tbody>
                            ${(data.categories || []).map(cat => `
                                <tr>
                                    <td>${cat.category_name}</td>
                                    <td class="right">${cat.percentage}%</td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
            </div>
            
            <!-- Dead Stock -->
            ${(data.deadStock || []).length > 0 ? `
                <div class="dashboard-section">
                    <h3>🔍 Dead Stock (No movement in 90+ days)</h3>
                    <table class="dashboard-table">
                        <thead>
                            <tr>
                                <th>Item</th>
                                <th>Qty</th>
                                <th>Value</th>
                                <th>Last Activity</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${data.deadStock.map(item => `
                                <tr>
                                    <td>${item.name}</td>
                                    <td>${item.quantity}</td>
                                    <td>$${formatNumber(item.total_value)}</td>
                                    <td>${item.days_since_activity} days ago</td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
            ` : ''}
        </div>
    `;
    
    // Render movement chart if Chart.js is available
    if (window.Chart && data.movement.daily_breakdown) {
        renderMovementChart(data.movement.daily_breakdown);
    }
}

function formatStatus(status) {
    const labels = {
        'out_of_stock': '🔴 OUT OF STOCK',
        'critical': '🔴 CRITICAL',
        'low': '🟡 LOW',
        'ok': '✅ OK'
    };
    return labels[status] || status;
}

function formatNumber(num) {
    return new Intl.NumberFormat('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(num || 0);
}
```

---

## Feature 2: Barcode Scanning

### Overview

Use the device camera to scan barcodes and instantly look up or add items.

### Implementation Options

| Option | Library | Pros | Cons |
|--------|---------|------|------|
| **QuaggaJS** | quaggajs | Fast, barcode only | Larger bundle |
| **Html5-QRCode** | html5-qrcode | QR + barcode, easy setup | Requires HTTPS |
| **ZXing** | @zxing/library | Full featured | Complex setup |

**Recommended: Html5-QRCode** — easiest to integrate, supports both QR and barcodes.

### Database Updates

```sql
-- Add barcode column if not exists (already in Phase 1, but ensure index)
CREATE INDEX IF NOT EXISTS idx_inventory_items_barcode 
    ON public.inventory_items(company_id, barcode) 
    WHERE barcode IS NOT NULL AND deleted_at IS NULL;

-- Lookup item by barcode
CREATE OR REPLACE FUNCTION public.lookup_by_barcode(
    p_company_id UUID,
    p_barcode TEXT
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    sku TEXT,
    barcode TEXT,
    quantity INTEGER,
    description TEXT,
    unit_cost DECIMAL,
    location_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.sku,
        i.barcode,
        i.quantity,
        i.description,
        i.unit_cost,
        l.name as location_name
    FROM inventory_items i
    LEFT JOIN inventory_locations l ON l.id = i.location_id
    WHERE i.company_id = p_company_id
    AND i.deleted_at IS NULL
    AND (i.barcode = p_barcode OR i.sku = p_barcode);
END;
$$;
```

### Frontend Implementation

```html
<!-- Add to HTML -->
<div id="scannerModal" class="modal" aria-hidden="true">
    <div class="modal-content">
        <h2>📷 Scan Barcode</h2>
        <div id="scannerPreview"></div>
        <div id="scanResult" class="scan-result" style="display:none;">
            <div class="scan-result-content"></div>
        </div>
        <div class="scanner-controls">
            <button class="btn" onclick="stopScanner()">Cancel</button>
            <input type="text" id="manualBarcode" placeholder="Or enter barcode manually" />
            <button class="btn primary" onclick="manualBarcodeSearch()">Search</button>
        </div>
    </div>
</div>

<!-- Scanner button in toolbar -->
<button class="btn icon-btn" onclick="startScanner()" title="Scan Barcode">
    📷
</button>
```

```javascript
// Include in <head>: <script src="https://unpkg.com/html5-qrcode"></script>

let html5QrCode = null;

async function startScanner() {
    show('scannerModal', true);
    document.getElementById('scanResult').style.display = 'none';
    
    html5QrCode = new Html5Qrcode("scannerPreview");
    
    try {
        await html5QrCode.start(
            { facingMode: "environment" },  // Back camera
            {
                fps: 10,
                qrbox: { width: 250, height: 250 }
            },
            onScanSuccess,
            onScanFailure
        );
    } catch (err) {
        console.error('Scanner error:', err);
        toast('Could not access camera', 'error');
    }
}

async function stopScanner() {
    if (html5QrCode) {
        await html5QrCode.stop();
        html5QrCode = null;
    }
    show('scannerModal', false);
}

async function onScanSuccess(decodedText, decodedResult) {
    // Vibrate for feedback
    if (navigator.vibrate) navigator.vibrate(100);
    
    // Stop scanning
    await html5QrCode.stop();
    
    // Look up the barcode
    await lookupBarcode(decodedText);
}

function onScanFailure(error) {
    // Ignore - scanning continues
}

async function lookupBarcode(barcode) {
    const resultDiv = document.getElementById('scanResult');
    const contentDiv = resultDiv.querySelector('.scan-result-content');
    
    resultDiv.style.display = 'block';
    contentDiv.innerHTML = '<p>Searching...</p>';
    
    try {
        const { data, error } = await SB.client.rpc('lookup_by_barcode', {
            p_company_id: SB.currentCompanyId,
            p_barcode: barcode
        });
        
        if (error) throw error;
        
        if (data && data.length > 0) {
            const item = data[0];
            contentDiv.innerHTML = `
                <div class="scan-found">
                    <h3>✅ Found: ${item.name}</h3>
                    <table class="scan-details">
                        <tr><td>SKU:</td><td>${item.sku || '-'}</td></tr>
                        <tr><td>Barcode:</td><td>${item.barcode || '-'}</td></tr>
                        <tr><td>Quantity:</td><td><strong>${item.quantity}</strong></td></tr>
                        <tr><td>Location:</td><td>${item.location_name || '-'}</td></tr>
                    </table>
                    <div class="scan-actions">
                        <button class="btn" onclick="adjustQuantityFromScan('${item.id}', 1)">+ Receive</button>
                        <button class="btn" onclick="adjustQuantityFromScan('${item.id}', -1)">- Remove</button>
                        <button class="btn primary" onclick="editItem('${item.id}'); stopScanner();">Edit Item</button>
                    </div>
                </div>
            `;
        } else {
            contentDiv.innerHTML = `
                <div class="scan-not-found">
                    <h3>❌ Not Found</h3>
                    <p>Barcode: <code>${barcode}</code></p>
                    <button class="btn primary" onclick="createItemFromScan('${barcode}')">
                        + Create New Item with This Barcode
                    </button>
                </div>
            `;
        }
    } catch (e) {
        contentDiv.innerHTML = `<p class="error">Error: ${e.message}</p>`;
    }
}

async function adjustQuantityFromScan(itemId, change) {
    try {
        // Get current quantity
        const { data: item } = await SB.client
            .from('inventory_items')
            .select('quantity')
            .eq('id', itemId)
            .single();
        
        const newQty = Math.max(0, item.quantity + change);
        
        // Update
        await SB.client
            .from('inventory_items')
            .update({ quantity: newQty })
            .eq('id', itemId);
        
        // Log transaction
        await SB.client.from('inventory_transactions').insert({
            company_id: SB.currentCompanyId,
            item_id: itemId,
            transaction_type: change > 0 ? 'received' : 'adjusted',
            quantity_change: change,
            quantity_before: item.quantity,
            quantity_after: newQty,
            notes: 'Updated via barcode scan'
        });
        
        toast(`Quantity ${change > 0 ? 'increased' : 'decreased'} to ${newQty}`);
        
        // Refresh scan result
        const barcodeInput = document.getElementById('manualBarcode');
        if (barcodeInput.value) {
            await lookupBarcode(barcodeInput.value);
        }
    } catch (e) {
        toast('Failed to update quantity', 'error');
    }
}

function createItemFromScan(barcode) {
    stopScanner();
    // Open create item modal with barcode pre-filled
    openCreateItemModal({ barcode });
}

function manualBarcodeSearch() {
    const barcode = document.getElementById('manualBarcode').value.trim();
    if (barcode) {
        lookupBarcode(barcode);
    }
}
```

---

## Feature 3: CSV Import/Export

### Overview

Allow users to import inventory from CSV and export current inventory.

### CSV Format

```csv
name,sku,barcode,description,quantity,unit_cost,low_stock_qty,category,location
"Widget A","WA-001","1234567890","Standard widget",100,12.50,10,"Electronics","Warehouse A"
"Gadget B","GB-002","0987654321","Premium gadget",50,25.00,5,"Hardware","Warehouse B"
```

### SQL Functions

```sql
-- Bulk import items
CREATE OR REPLACE FUNCTION public.bulk_import_items(
    p_company_id UUID,
    p_items JSONB,
    p_update_existing BOOLEAN DEFAULT false
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_item JSONB;
    v_inserted INTEGER := 0;
    v_updated INTEGER := 0;
    v_skipped INTEGER := 0;
    v_errors TEXT[] := '{}';
    v_category_id UUID;
    v_location_id UUID;
BEGIN
    IF NOT public.user_can_write(p_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Create snapshot before import
    PERFORM public.create_snapshot(
        p_company_id,
        'Pre-Import Backup',
        'Automatic backup before CSV import',
        'pre_import'
    );
    
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        BEGIN
            -- Lookup category by name
            v_category_id := NULL;
            IF v_item->>'category' IS NOT NULL AND v_item->>'category' != '' THEN
                SELECT id INTO v_category_id
                FROM inventory_categories
                WHERE company_id = p_company_id 
                AND lower(name) = lower(v_item->>'category')
                AND deleted_at IS NULL;
                
                -- Create category if not exists
                IF v_category_id IS NULL THEN
                    INSERT INTO inventory_categories (company_id, name)
                    VALUES (p_company_id, v_item->>'category')
                    RETURNING id INTO v_category_id;
                END IF;
            END IF;
            
            -- Lookup location by name
            v_location_id := NULL;
            IF v_item->>'location' IS NOT NULL AND v_item->>'location' != '' THEN
                SELECT id INTO v_location_id
                FROM inventory_locations
                WHERE company_id = p_company_id 
                AND lower(name) = lower(v_item->>'location')
                AND deleted_at IS NULL;
                
                -- Create location if not exists
                IF v_location_id IS NULL THEN
                    INSERT INTO inventory_locations (company_id, name)
                    VALUES (p_company_id, v_item->>'location')
                    RETURNING id INTO v_location_id;
                END IF;
            END IF;
            
            -- Try to insert or update
            IF p_update_existing AND (v_item->>'sku' IS NOT NULL OR v_item->>'barcode' IS NOT NULL) THEN
                -- Try update first
                UPDATE inventory_items
                SET 
                    name = COALESCE(v_item->>'name', name),
                    description = COALESCE(v_item->>'description', description),
                    quantity = COALESCE((v_item->>'quantity')::integer, quantity),
                    unit_cost = COALESCE((v_item->>'unit_cost')::decimal, unit_cost),
                    low_stock_qty = COALESCE((v_item->>'low_stock_qty')::integer, low_stock_qty),
                    barcode = COALESCE(v_item->>'barcode', barcode),
                    category_id = COALESCE(v_category_id, category_id),
                    location_id = COALESCE(v_location_id, location_id),
                    updated_at = now()
                WHERE company_id = p_company_id
                AND deleted_at IS NULL
                AND (
                    (sku IS NOT NULL AND sku = v_item->>'sku')
                    OR (barcode IS NOT NULL AND barcode = v_item->>'barcode')
                );
                
                IF FOUND THEN
                    v_updated := v_updated + 1;
                    CONTINUE;
                END IF;
            END IF;
            
            -- Insert new item
            INSERT INTO inventory_items (
                company_id, name, sku, barcode, description,
                quantity, unit_cost, low_stock_qty,
                category_id, location_id, created_by
            ) VALUES (
                p_company_id,
                v_item->>'name',
                v_item->>'sku',
                v_item->>'barcode',
                v_item->>'description',
                COALESCE((v_item->>'quantity')::integer, 0),
                (v_item->>'unit_cost')::decimal,
                (v_item->>'low_stock_qty')::integer,
                v_category_id,
                v_location_id,
                auth.uid()
            );
            
            v_inserted := v_inserted + 1;
            
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped + 1;
            v_errors := array_append(v_errors, 
                'Row ' || v_item->>'name' || ': ' || SQLERRM);
        END;
    END LOOP;
    
    RETURN json_build_object(
        'success', true,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped,
        'errors', v_errors
    );
END;
$$;

-- Export items as JSON (convert to CSV in frontend)
CREATE OR REPLACE FUNCTION public.export_items(p_company_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;
    
    RETURN (
        SELECT json_agg(row_to_json(t))
        FROM (
            SELECT 
                i.name,
                i.sku,
                i.barcode,
                i.description,
                i.quantity,
                i.unit_cost,
                i.low_stock_qty,
                c.name as category,
                l.name as location,
                i.created_at
            FROM inventory_items i
            LEFT JOIN inventory_categories c ON c.id = i.category_id
            LEFT JOIN inventory_locations l ON l.id = i.location_id
            WHERE i.company_id = p_company_id
            AND i.deleted_at IS NULL
            ORDER BY i.name
        ) t
    );
END;
$$;
```

### Frontend Implementation

```html
<!-- Import/Export buttons in toolbar -->
<button class="btn" onclick="showImportModal()">📥 Import CSV</button>
<button class="btn" onclick="exportToCSV()">📤 Export CSV</button>

<!-- Import Modal -->
<div id="importModal" class="modal" aria-hidden="true">
    <div class="modal-content">
        <h2>📥 Import from CSV</h2>
        
        <div class="import-instructions">
            <p>Upload a CSV file with the following columns:</p>
            <code>name, sku, barcode, description, quantity, unit_cost, low_stock_qty, category, location</code>
            <p><a href="#" onclick="downloadSampleCSV(); return false;">Download sample template</a></p>
        </div>
        
        <div class="form-group">
            <label for="csvFile">Select CSV File</label>
            <input type="file" id="csvFile" accept=".csv" onchange="previewCSV(this)" />
        </div>
        
        <div id="csvPreview" style="display:none;">
            <h4>Preview (first 5 rows)</h4>
            <div class="csv-preview-table"></div>
            <p class="csv-stats"></p>
        </div>
        
        <div class="form-group">
            <label>
                <input type="checkbox" id="updateExisting" />
                Update existing items (match by SKU or barcode)
            </label>
        </div>
        
        <div class="modal-actions">
            <button class="btn" onclick="show('importModal', false)">Cancel</button>
            <button class="btn primary" id="importBtn" onclick="runImport()" disabled>Import</button>
        </div>
        
        <div id="importResults" style="display:none;"></div>
    </div>
</div>
```

```javascript
let pendingImportData = null;

function showImportModal() {
    pendingImportData = null;
    document.getElementById('csvFile').value = '';
    document.getElementById('csvPreview').style.display = 'none';
    document.getElementById('importResults').style.display = 'none';
    document.getElementById('importBtn').disabled = true;
    show('importModal', true);
}

function previewCSV(input) {
    const file = input.files[0];
    if (!file) return;
    
    const reader = new FileReader();
    reader.onload = function(e) {
        const csv = e.target.result;
        const lines = csv.split('\n');
        const headers = lines[0].split(',').map(h => h.trim().toLowerCase().replace(/"/g, ''));
        
        // Parse rows
        const rows = [];
        for (let i = 1; i < lines.length; i++) {
            if (!lines[i].trim()) continue;
            const values = parseCSVLine(lines[i]);
            const row = {};
            headers.forEach((h, idx) => {
                row[h] = values[idx]?.trim().replace(/"/g, '') || '';
            });
            rows.push(row);
        }
        
        pendingImportData = rows;
        
        // Show preview
        const previewDiv = document.getElementById('csvPreview');
        const tableDiv = previewDiv.querySelector('.csv-preview-table');
        const statsP = previewDiv.querySelector('.csv-stats');
        
        tableDiv.innerHTML = `
            <table class="preview-table">
                <thead>
                    <tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr>
                </thead>
                <tbody>
                    ${rows.slice(0, 5).map(row => `
                        <tr>${headers.map(h => `<td>${row[h] || ''}</td>`).join('')}</tr>
                    `).join('')}
                </tbody>
            </table>
        `;
        statsP.textContent = `Total rows: ${rows.length}`;
        previewDiv.style.display = 'block';
        document.getElementById('importBtn').disabled = false;
    };
    reader.readAsText(file);
}

function parseCSVLine(line) {
    const result = [];
    let current = '';
    let inQuotes = false;
    
    for (let char of line) {
        if (char === '"') {
            inQuotes = !inQuotes;
        } else if (char === ',' && !inQuotes) {
            result.push(current);
            current = '';
        } else {
            current += char;
        }
    }
    result.push(current);
    return result;
}

async function runImport() {
    if (!pendingImportData || pendingImportData.length === 0) {
        toast('No data to import', 'error');
        return;
    }
    
    const updateExisting = document.getElementById('updateExisting').checked;
    const resultsDiv = document.getElementById('importResults');
    
    resultsDiv.innerHTML = '<p>Importing...</p>';
    resultsDiv.style.display = 'block';
    
    try {
        const { data, error } = await SB.client.rpc('bulk_import_items', {
            p_company_id: SB.currentCompanyId,
            p_items: pendingImportData,
            p_update_existing: updateExisting
        });
        
        if (error) throw error;
        
        if (data.success) {
            resultsDiv.innerHTML = `
                <div class="import-success">
                    <h4>✅ Import Complete</h4>
                    <ul>
                        <li>Inserted: ${data.inserted}</li>
                        <li>Updated: ${data.updated}</li>
                        <li>Skipped: ${data.skipped}</li>
                    </ul>
                    ${data.errors.length > 0 ? `
                        <details>
                            <summary>Errors (${data.errors.length})</summary>
                            <ul>${data.errors.map(e => `<li>${e}</li>`).join('')}</ul>
                        </details>
                    ` : ''}
                </div>
            `;
            
            // Refresh inventory
            await sbFetchItems();
        } else {
            throw new Error(data.error);
        }
    } catch (e) {
        resultsDiv.innerHTML = `<div class="import-error">❌ Import failed: ${e.message}</div>`;
    }
}

async function exportToCSV() {
    try {
        const { data, error } = await SB.client.rpc('export_items', {
            p_company_id: SB.currentCompanyId
        });
        
        if (error) throw error;
        
        if (!data || data.length === 0) {
            toast('No items to export', 'warning');
            return;
        }
        
        // Convert JSON to CSV
        const headers = ['name', 'sku', 'barcode', 'description', 'quantity', 'unit_cost', 'low_stock_qty', 'category', 'location'];
        const csvRows = [headers.join(',')];
        
        for (const item of data) {
            const row = headers.map(h => {
                const val = item[h] ?? '';
                // Escape quotes and wrap in quotes if contains comma
                const escaped = String(val).replace(/"/g, '""');
                return escaped.includes(',') ? `"${escaped}"` : escaped;
            });
            csvRows.push(row.join(','));
        }
        
        const csv = csvRows.join('\n');
        
        // Download
        const blob = new Blob([csv], { type: 'text/csv' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `inventory-export-${new Date().toISOString().split('T')[0]}.csv`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
        
        toast(`Exported ${data.length} items`);
    } catch (e) {
        toast('Export failed: ' + e.message, 'error');
    }
}

function downloadSampleCSV() {
    const sample = `name,sku,barcode,description,quantity,unit_cost,low_stock_qty,category,location
"Widget A","WA-001","1234567890","Standard widget",100,12.50,10,"Electronics","Warehouse A"
"Gadget B","GB-002","0987654321","Premium gadget",50,25.00,5,"Hardware","Warehouse B"`;
    
    const blob = new Blob([sample], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'inventory-import-template.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}
```

---

## Feature 4: Purchase Orders

### Overview

Track orders placed with vendors before inventory arrives.

### Database Schema

```sql
-- ============================================================================
-- PURCHASE ORDERS
-- ============================================================================

-- Vendors table
CREATE TABLE IF NOT EXISTS public.vendors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    contact_name TEXT,
    email TEXT,
    phone TEXT,
    address TEXT,
    website TEXT,
    payment_terms TEXT,
    lead_time_days INTEGER,
    notes TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_vendors_company ON public.vendors(company_id);
CREATE INDEX IF NOT EXISTS idx_vendors_active ON public.vendors(company_id) WHERE is_active = true AND deleted_at IS NULL;

-- Purchase orders
CREATE TABLE IF NOT EXISTS public.purchase_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    vendor_id UUID REFERENCES public.vendors(id),
    
    -- PO identification
    po_number TEXT NOT NULL,
    
    -- Status tracking
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'sent', 'confirmed', 'partial', 'received', 'cancelled')),
    
    -- Dates
    order_date DATE DEFAULT CURRENT_DATE,
    expected_date DATE,
    received_date DATE,
    
    -- Totals (calculated)
    subtotal DECIMAL(10,2) DEFAULT 0,
    tax DECIMAL(10,2) DEFAULT 0,
    shipping DECIMAL(10,2) DEFAULT 0,
    total DECIMAL(10,2) DEFAULT 0,
    
    -- Notes
    notes TEXT,
    vendor_notes TEXT,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    
    UNIQUE(company_id, po_number)
);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_company ON public.purchase_orders(company_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_status ON public.purchase_orders(company_id, status);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_vendor ON public.purchase_orders(vendor_id);

-- Purchase order line items
CREATE TABLE IF NOT EXISTS public.purchase_order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
    item_id UUID REFERENCES public.inventory_items(id),
    
    -- Item details (denormalized for historical record)
    item_name TEXT NOT NULL,
    item_sku TEXT,
    
    -- Quantities
    quantity_ordered INTEGER NOT NULL,
    quantity_received INTEGER DEFAULT 0,
    
    -- Pricing
    unit_cost DECIMAL(10,2) NOT NULL,
    line_total DECIMAL(10,2) GENERATED ALWAYS AS (quantity_ordered * unit_cost) STORED,
    
    -- Notes
    notes TEXT,
    
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_po_items_order ON public.purchase_order_items(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_po_items_item ON public.purchase_order_items(item_id);

-- Generate PO number
CREATE OR REPLACE FUNCTION public.generate_po_number(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_year TEXT := to_char(CURRENT_DATE, 'YYYY');
    v_count INTEGER;
    v_number TEXT;
BEGIN
    SELECT COUNT(*) + 1 INTO v_count
    FROM public.purchase_orders
    WHERE company_id = p_company_id
    AND po_number LIKE 'PO-' || v_year || '-%';
    
    v_number := 'PO-' || v_year || '-' || lpad(v_count::text, 4, '0');
    RETURN v_number;
END;
$$;

-- Create purchase order
CREATE OR REPLACE FUNCTION public.create_purchase_order(
    p_company_id UUID,
    p_vendor_id UUID,
    p_items JSONB,
    p_expected_date DATE DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_po_id UUID;
    v_po_number TEXT;
    v_item JSONB;
    v_subtotal DECIMAL := 0;
BEGIN
    IF NOT public.user_can_write(p_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Generate PO number
    v_po_number := public.generate_po_number(p_company_id);
    
    -- Create PO header
    INSERT INTO public.purchase_orders (
        company_id, vendor_id, po_number, expected_date, notes, created_by
    ) VALUES (
        p_company_id, p_vendor_id, v_po_number, p_expected_date, p_notes, auth.uid()
    )
    RETURNING id INTO v_po_id;
    
    -- Add line items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        INSERT INTO public.purchase_order_items (
            purchase_order_id, item_id, item_name, item_sku, quantity_ordered, unit_cost
        ) VALUES (
            v_po_id,
            (v_item->>'item_id')::uuid,
            v_item->>'item_name',
            v_item->>'item_sku',
            (v_item->>'quantity')::integer,
            (v_item->>'unit_cost')::decimal
        );
        
        v_subtotal := v_subtotal + ((v_item->>'quantity')::integer * (v_item->>'unit_cost')::decimal);
    END LOOP;
    
    -- Update totals
    UPDATE public.purchase_orders
    SET subtotal = v_subtotal, total = v_subtotal
    WHERE id = v_po_id;
    
    RETURN json_build_object(
        'success', true,
        'purchase_order_id', v_po_id,
        'po_number', v_po_number
    );
END;
$$;

-- Receive items against PO
CREATE OR REPLACE FUNCTION public.receive_po_items(
    p_po_id UUID,
    p_items JSONB  -- [{ po_item_id, quantity_received }]
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_po RECORD;
    v_item JSONB;
    v_po_item RECORD;
    v_all_received BOOLEAN := true;
    v_any_received BOOLEAN := false;
BEGIN
    -- Get PO
    SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'PO not found');
    END IF;
    
    IF NOT public.user_can_write(v_po.company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Process each item
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT * INTO v_po_item
        FROM purchase_order_items
        WHERE id = (v_item->>'po_item_id')::uuid;
        
        IF FOUND THEN
            -- Update received quantity
            UPDATE purchase_order_items
            SET quantity_received = quantity_received + (v_item->>'quantity_received')::integer
            WHERE id = v_po_item.id;
            
            -- Update inventory
            IF v_po_item.item_id IS NOT NULL THEN
                -- Get current quantity
                DECLARE
                    v_current_qty INTEGER;
                BEGIN
                    SELECT quantity INTO v_current_qty
                    FROM inventory_items WHERE id = v_po_item.item_id;
                    
                    -- Update inventory quantity
                    UPDATE inventory_items
                    SET quantity = quantity + (v_item->>'quantity_received')::integer
                    WHERE id = v_po_item.item_id;
                    
                    -- Log transaction
                    INSERT INTO inventory_transactions (
                        company_id, item_id, transaction_type,
                        quantity_change, quantity_before, quantity_after,
                        reference_number, notes, created_by
                    ) VALUES (
                        v_po.company_id,
                        v_po_item.item_id,
                        'received',
                        (v_item->>'quantity_received')::integer,
                        v_current_qty,
                        v_current_qty + (v_item->>'quantity_received')::integer,
                        v_po.po_number,
                        'Received from PO ' || v_po.po_number,
                        auth.uid()
                    );
                END;
            END IF;
            
            v_any_received := true;
        END IF;
    END LOOP;
    
    -- Check if all items fully received
    SELECT NOT EXISTS (
        SELECT 1 FROM purchase_order_items
        WHERE purchase_order_id = p_po_id
        AND quantity_received < quantity_ordered
    ) INTO v_all_received;
    
    -- Update PO status
    UPDATE purchase_orders
    SET 
        status = CASE 
            WHEN v_all_received THEN 'received'
            WHEN v_any_received THEN 'partial'
            ELSE status
        END,
        received_date = CASE WHEN v_all_received THEN CURRENT_DATE ELSE received_date END,
        updated_at = now()
    WHERE id = p_po_id;
    
    RETURN json_build_object(
        'success', true,
        'all_received', v_all_received
    );
END;
$$;

-- Get PO with items
CREATE OR REPLACE FUNCTION public.get_purchase_order(p_po_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_po RECORD;
    v_items JSON;
BEGIN
    SELECT * INTO v_po FROM purchase_orders WHERE id = p_po_id;
    
    IF NOT FOUND OR NOT (v_po.company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN json_build_object('error', 'Not found');
    END IF;
    
    SELECT json_agg(row_to_json(t)) INTO v_items
    FROM (
        SELECT 
            poi.*,
            i.quantity as current_stock
        FROM purchase_order_items poi
        LEFT JOIN inventory_items i ON i.id = poi.item_id
        WHERE poi.purchase_order_id = p_po_id
    ) t;
    
    RETURN json_build_object(
        'id', v_po.id,
        'po_number', v_po.po_number,
        'vendor_id', v_po.vendor_id,
        'status', v_po.status,
        'order_date', v_po.order_date,
        'expected_date', v_po.expected_date,
        'subtotal', v_po.subtotal,
        'total', v_po.total,
        'notes', v_po.notes,
        'items', v_items
    );
END;
$$;

-- List purchase orders
CREATE OR REPLACE FUNCTION public.list_purchase_orders(
    p_company_id UUID,
    p_status TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID,
    po_number TEXT,
    vendor_name TEXT,
    status TEXT,
    order_date DATE,
    expected_date DATE,
    total DECIMAL,
    item_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        po.id,
        po.po_number,
        v.name as vendor_name,
        po.status,
        po.order_date,
        po.expected_date,
        po.total,
        (SELECT COUNT(*) FROM purchase_order_items WHERE purchase_order_id = po.id)
    FROM purchase_orders po
    LEFT JOIN vendors v ON v.id = po.vendor_id
    WHERE po.company_id = p_company_id
    AND (p_status IS NULL OR po.status = p_status)
    ORDER BY po.order_date DESC;
END;
$$;

-- RLS for new tables
ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view company vendors"
    ON public.vendors FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

CREATE POLICY "Writers can manage vendors"
    ON public.vendors FOR ALL
    USING (public.user_can_write(company_id));

CREATE POLICY "Users can view company POs"
    ON public.purchase_orders FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

CREATE POLICY "Writers can manage POs"
    ON public.purchase_orders FOR ALL
    USING (public.user_can_write(company_id));

CREATE POLICY "Users can view PO items"
    ON public.purchase_order_items FOR SELECT
    USING (purchase_order_id IN (
        SELECT id FROM purchase_orders WHERE company_id IN (SELECT public.get_user_company_ids())
    ));

CREATE POLICY "Writers can manage PO items"
    ON public.purchase_order_items FOR ALL
    USING (purchase_order_id IN (
        SELECT id FROM purchase_orders WHERE company_id IN (SELECT public.get_user_company_ids()) 
    ));
```

---

## Feature 5: Vendor Management

### Database (included in Feature 4)

The `vendors` table is created in the Purchase Orders section above.

### Additional SQL Functions

```sql
-- List vendors
CREATE OR REPLACE FUNCTION public.list_vendors(p_company_id UUID)
RETURNS TABLE (
    id UUID,
    name TEXT,
    contact_name TEXT,
    email TEXT,
    phone TEXT,
    is_active BOOLEAN,
    po_count BIGINT,
    last_order_date DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (p_company_id IN (SELECT public.get_user_company_ids())) THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        v.id,
        v.name,
        v.contact_name,
        v.email,
        v.phone,
        v.is_active,
        (SELECT COUNT(*) FROM purchase_orders WHERE vendor_id = v.id),
        (SELECT MAX(order_date) FROM purchase_orders WHERE vendor_id = v.id)
    FROM vendors v
    WHERE v.company_id = p_company_id
    AND v.deleted_at IS NULL
    ORDER BY v.name;
END;
$$;

-- Create/Update vendor
CREATE OR REPLACE FUNCTION public.upsert_vendor(
    p_company_id UUID,
    p_name TEXT,
    p_contact_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_address TEXT DEFAULT NULL,
    p_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vendor_id UUID;
BEGIN
    IF NOT public.user_can_write(p_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    IF p_id IS NOT NULL THEN
        UPDATE vendors
        SET name = p_name, contact_name = p_contact_name, email = p_email,
            phone = p_phone, address = p_address, updated_at = now()
        WHERE id = p_id AND company_id = p_company_id
        RETURNING id INTO v_vendor_id;
    ELSE
        INSERT INTO vendors (company_id, name, contact_name, email, phone, address)
        VALUES (p_company_id, p_name, p_contact_name, p_email, p_phone, p_address)
        RETURNING id INTO v_vendor_id;
    END IF;
    
    RETURN json_build_object('success', true, 'vendor_id', v_vendor_id);
END;
$$;
```

---

## Feature 6: Low Stock Email Alerts

### Overview

Send email notifications when items fall below their reorder point.

### Implementation via Supabase Edge Function

Create: `supabase/functions/low-stock-alert/index.ts`

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    try {
        const supabase = createClient(
            Deno.env.get('SUPABASE_URL') ?? '',
            Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        )

        // Get all companies with low stock items
        const { data: lowStockData, error } = await supabase.rpc('get_companies_with_low_stock')
        
        if (error) throw error

        for (const company of lowStockData || []) {
            // Get admin emails for this company
            const { data: admins } = await supabase
                .from('company_members')
                .select('user_id, profiles(email)')
                .eq('company_id', company.company_id)
                .in('role', ['admin', 'owner'])
            
            const adminEmails = admins?.map(a => a.profiles?.email).filter(Boolean)
            
            if (!adminEmails?.length) continue
            
            // Send email via Mailtrap
            const emailBody = `
                <h2>Low Stock Alert - ${company.company_name}</h2>
                <p>The following items are running low:</p>
                <table border="1" cellpadding="8">
                    <tr><th>Item</th><th>Current</th><th>Reorder At</th></tr>
                    ${company.items.map(item => `
                        <tr>
                            <td>${item.name}</td>
                            <td>${item.quantity}</td>
                            <td>${item.low_stock_qty}</td>
                        </tr>
                    `).join('')}
                </table>
                <p>
                    <a href="https://inventory.modulus-software.com">
                        View Inventory
                    </a>
                </p>
            `
            
            // Send via Mailtrap API
            await fetch('https://send.api.mailtrap.io/api/send', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Api-Token': Deno.env.get('MAILTRAP_API_KEY') ?? ''
                },
                body: JSON.stringify({
                    from: { email: 'noreply@modulus-software.com', name: 'Inventory Manager' },
                    to: adminEmails.map(email => ({ email })),
                    subject: `⚠️ Low Stock Alert: ${company.items.length} items need attention`,
                    html: emailBody
                })
            })
        }

        return new Response(
            JSON.stringify({ success: true }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
    } catch (error) {
        return new Response(
            JSON.stringify({ error: error.message }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
    }
})
```

### SQL Helper Function

```sql
CREATE OR REPLACE FUNCTION public.get_companies_with_low_stock()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN (
        SELECT json_agg(row_to_json(c))
        FROM (
            SELECT 
                company_id,
                (SELECT name FROM companies WHERE id = company_id) as company_name,
                json_agg(json_build_object(
                    'name', name,
                    'quantity', quantity,
                    'low_stock_qty', low_stock_qty
                )) as items
            FROM inventory_items
            WHERE deleted_at IS NULL
            AND low_stock_qty IS NOT NULL
            AND quantity <= low_stock_qty
            AND quantity > 0
            GROUP BY company_id
        ) c
    );
END;
$$;
```

### Schedule with pg_cron or External Scheduler

```sql
-- If pg_cron is available:
SELECT cron.schedule(
    'low-stock-alert',
    '0 8 * * *',  -- Daily at 8 AM
    $$
    SELECT net.http_post(
        url := 'https://your-project.supabase.co/functions/v1/low-stock-alert',
        headers := '{"Authorization": "Bearer YOUR_SERVICE_KEY"}'::jsonb
    );
    $$
);
```

---

## Feature 7: Stock Transfers

### Overview

Transfer inventory between locations.

### Database Schema

```sql
-- Stock transfers table
CREATE TABLE IF NOT EXISTS public.stock_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    
    -- Transfer number
    transfer_number TEXT NOT NULL,
    
    -- Locations
    from_location_id UUID REFERENCES public.inventory_locations(id),
    to_location_id UUID NOT NULL REFERENCES public.inventory_locations(id),
    
    -- Status
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_transit', 'completed', 'cancelled')),
    
    -- Notes
    notes TEXT,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    completed_at TIMESTAMPTZ,
    completed_by UUID REFERENCES auth.users(id),
    
    UNIQUE(company_id, transfer_number)
);

CREATE INDEX IF NOT EXISTS idx_transfers_company ON public.stock_transfers(company_id);
CREATE INDEX IF NOT EXISTS idx_transfers_status ON public.stock_transfers(company_id, status);

-- Transfer line items
CREATE TABLE IF NOT EXISTS public.stock_transfer_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id),
    
    quantity INTEGER NOT NULL,
    
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_transfer_items_transfer ON public.stock_transfer_items(transfer_id);

-- Create transfer
CREATE OR REPLACE FUNCTION public.create_stock_transfer(
    p_company_id UUID,
    p_from_location_id UUID,
    p_to_location_id UUID,
    p_items JSONB,  -- [{ item_id, quantity }]
    p_notes TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_transfer_id UUID;
    v_transfer_number TEXT;
    v_item JSONB;
BEGIN
    IF NOT public.user_can_write(p_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Generate transfer number
    v_transfer_number := 'TRF-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || 
        lpad((SELECT COUNT(*) + 1 FROM stock_transfers WHERE company_id = p_company_id)::text, 4, '0');
    
    -- Create transfer header
    INSERT INTO stock_transfers (
        company_id, transfer_number, from_location_id, to_location_id, notes, created_by
    ) VALUES (
        p_company_id, v_transfer_number, p_from_location_id, p_to_location_id, p_notes, auth.uid()
    )
    RETURNING id INTO v_transfer_id;
    
    -- Add items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        INSERT INTO stock_transfer_items (transfer_id, item_id, quantity)
        VALUES (v_transfer_id, (v_item->>'item_id')::uuid, (v_item->>'quantity')::integer);
    END LOOP;
    
    RETURN json_build_object('success', true, 'transfer_id', v_transfer_id, 'transfer_number', v_transfer_number);
END;
$$;

-- Complete transfer (move inventory)
CREATE OR REPLACE FUNCTION public.complete_stock_transfer(p_transfer_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_transfer RECORD;
    v_item RECORD;
    v_current_qty INTEGER;
BEGIN
    SELECT * INTO v_transfer FROM stock_transfers WHERE id = p_transfer_id;
    
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Transfer not found');
    END IF;
    
    IF NOT public.user_can_write(v_transfer.company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    IF v_transfer.status = 'completed' THEN
        RETURN json_build_object('success', false, 'error', 'Transfer already completed');
    END IF;
    
    -- Process each item
    FOR v_item IN 
        SELECT sti.*, i.quantity as current_qty, i.name
        FROM stock_transfer_items sti
        JOIN inventory_items i ON i.id = sti.item_id
        WHERE sti.transfer_id = p_transfer_id
    LOOP
        -- Update location (assuming single-location per item for simplicity)
        -- For multi-location, you'd need a separate stock_by_location table
        UPDATE inventory_items
        SET location_id = v_transfer.to_location_id, updated_at = now()
        WHERE id = v_item.item_id;
        
        -- Log transaction
        INSERT INTO inventory_transactions (
            company_id, item_id, transaction_type,
            quantity_change, quantity_before, quantity_after,
            from_location_id, to_location_id,
            reference_number, notes, created_by
        ) VALUES (
            v_transfer.company_id,
            v_item.item_id,
            'transferred',
            0,  -- No quantity change, just location
            v_item.current_qty,
            v_item.current_qty,
            v_transfer.from_location_id,
            v_transfer.to_location_id,
            v_transfer.transfer_number,
            'Transferred ' || v_item.quantity || ' units',
            auth.uid()
        );
    END LOOP;
    
    -- Update transfer status
    UPDATE stock_transfers
    SET status = 'completed', completed_at = now(), completed_by = auth.uid()
    WHERE id = p_transfer_id;
    
    RETURN json_build_object('success', true);
END;
$$;

-- RLS
ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view company transfers"
    ON public.stock_transfers FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

CREATE POLICY "Writers can manage transfers"
    ON public.stock_transfers FOR ALL
    USING (public.user_can_write(company_id));

CREATE POLICY "Users can view transfer items"
    ON public.stock_transfer_items FOR SELECT
    USING (transfer_id IN (
        SELECT id FROM stock_transfers WHERE company_id IN (SELECT public.get_user_company_ids())
    ));

CREATE POLICY "Writers can manage transfer items"
    ON public.stock_transfer_items FOR ALL
    USING (transfer_id IN (
        SELECT id FROM stock_transfers WHERE company_id IN (SELECT public.get_user_company_ids())
    ));
```

---

## Database Migration

Create file: `supabase/migrations/003_phase2_features.sql`

Combine all SQL from the features above into a single migration file.

---

## Frontend Implementation

### Navigation Updates

```html
<!-- Add to navigation -->
<nav class="main-nav">
    <a href="#" onclick="showView('dashboard')">📊 Dashboard</a>
    <a href="#" onclick="showView('inventory')">📦 Inventory</a>
    <a href="#" onclick="showView('orders')">📋 Orders</a>
    <a href="#" onclick="showView('purchase-orders')">🛒 Purchase Orders</a>
    <a href="#" onclick="showView('vendors')">🏢 Vendors</a>
    <a href="#" onclick="showView('locations')">📍 Locations</a>
</nav>
```

---

## Testing Checklist

### Reporting Dashboard
- [ ] Summary cards show correct totals
- [ ] Low stock items list is accurate
- [ ] Movement chart displays correctly
- [ ] Dead stock identifies old items
- [ ] Category breakdown totals 100%

### Barcode Scanning
- [ ] Camera permission prompt works
- [ ] Barcode detected and decoded
- [ ] Item lookup returns correct item
- [ ] +/- quantity buttons work
- [ ] "Not found" shows create option

### CSV Import/Export
- [ ] Export creates valid CSV
- [ ] Sample template downloads
- [ ] Import preview shows data
- [ ] Categories/locations auto-created
- [ ] Update existing works
- [ ] Error handling for bad data

### Purchase Orders
- [ ] PO number auto-generates
- [ ] Items can be added
- [ ] Totals calculate correctly
- [ ] Receive updates inventory
- [ ] Partial receive tracks correctly

### Vendors
- [ ] Create/edit/delete vendors
- [ ] Vendor dropdown in PO
- [ ] Contact info displays

### Low Stock Alerts
- [ ] Edge function runs
- [ ] Correct items identified
- [ ] Email received by admins

### Stock Transfers
- [ ] Create transfer between locations
- [ ] Complete transfer updates location
- [ ] Transaction logged correctly

---

## Rollout Plan

1. **Deploy Phase 1 first** (if not already done)
2. **Run Phase 2 migration**: `supabase db push`
3. **Deploy Edge Function** for email alerts
4. **Update frontend** with new features
5. **Test all features** in staging
6. **Deploy to production**

---

## Future Enhancements (Phase 3+)

- [ ] QuickBooks/Xero integration
- [ ] Shopify/WooCommerce sync
- [ ] Mobile PWA
- [ ] Lot/batch tracking
- [ ] Bin/zone locations
- [ ] Demand forecasting
- [ ] API for custom integrations
