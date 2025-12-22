-- ============================================================================
-- INVENTORY MANAGER DATABASE SCHEMA
-- ============================================================================
-- 
-- This migration creates the complete database schema for the Inventory Manager
-- application with Row Level Security (RLS) policies that enforce multi-tenant
-- data isolation at the database level.
--
-- SECURITY MODEL:
-- - Every table has RLS enabled
-- - All policies use company_id from the JWT's app_metadata
-- - Users can ONLY access data belonging to their company
-- - This cannot be bypassed by application code
--
-- PREREQUISITES:
-- - Supabase project with Auth enabled
-- - Users must have app_metadata.company_id set during registration
--
-- ============================================================================

-- ============================================================================
-- SECTION 1: COMPANIES TABLE
-- ============================================================================
-- The root entity for multi-tenancy. Every other table references this.

CREATE TABLE IF NOT EXISTS companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Company identification
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,  -- URL-friendly identifier
    
    -- Subscription/billing tier (affects rate limits, features)
    tier TEXT NOT NULL DEFAULT 'standard' 
        CHECK (tier IN ('standard', 'premium', 'enterprise')),
    
    -- Contact information
    email TEXT,
    phone TEXT,
    
    -- Address (optional)
    address_line1 TEXT,
    address_line2 TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT DEFAULT 'US',
    
    -- Settings stored as JSONB for flexibility
    settings JSONB DEFAULT '{}'::jsonb,
    
    -- Metadata
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for slug lookups (used in URLs)
CREATE UNIQUE INDEX idx_companies_slug ON companies (slug);

-- Index for active companies
CREATE INDEX idx_companies_active ON companies (is_active) WHERE is_active = true;

-- Trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_companies_updated_at
    BEFORE UPDATE ON companies
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- SECTION 2: USER PROFILES TABLE
-- ============================================================================
-- Extends Supabase auth.users with application-specific data.
-- Links users to companies.

CREATE TABLE IF NOT EXISTS user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    
    -- User information
    full_name TEXT,
    avatar_url TEXT,
    
    -- Role within the company
    role TEXT NOT NULL DEFAULT 'member'
        CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
    
    -- Preferences
    preferences JSONB DEFAULT '{}'::jsonb,
    
    -- Metadata
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for company user lookups
CREATE INDEX idx_user_profiles_company ON user_profiles (company_id);

-- Index for active users
CREATE INDEX idx_user_profiles_active ON user_profiles (is_active) WHERE is_active = true;

CREATE TRIGGER update_user_profiles_updated_at
    BEFORE UPDATE ON user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- SECTION 3: INVENTORY TABLE
-- ============================================================================
-- Core inventory items table with comprehensive fields.

CREATE TABLE IF NOT EXISTS inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    
    -- Core identification
    name TEXT NOT NULL,
    sku TEXT NOT NULL,
    description TEXT,
    
    -- Quantity tracking
    quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    unit TEXT DEFAULT 'each',
    
    -- Organization
    category TEXT,
    location TEXT,
    
    -- Reorder management
    reorder_point INTEGER CHECK (reorder_point >= 0),
    reorder_quantity INTEGER CHECK (reorder_quantity > 0),
    
    -- Financial
    unit_cost DECIMAL(12, 2) CHECK (unit_cost >= 0),
    
    -- Supplier information
    supplier TEXT,
    supplier_sku TEXT,  -- Supplier's SKU for this item
    
    -- Identifiers
    barcode TEXT,
    
    -- Additional data
    notes TEXT,
    custom_fields JSONB DEFAULT '{}'::jsonb,
    
    -- Image/attachment references (stored in Supabase Storage)
    image_url TEXT,
    
    -- Soft delete support
    is_archived BOOLEAN NOT NULL DEFAULT false,
    archived_at TIMESTAMPTZ,
    archived_by UUID REFERENCES auth.users(id),
    
    -- Audit fields
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    updated_by UUID REFERENCES auth.users(id),
    
    -- Unique SKU per company
    CONSTRAINT unique_sku_per_company UNIQUE (company_id, sku)
);

-- Performance indexes
CREATE INDEX idx_inventory_company ON inventory (company_id);
CREATE INDEX idx_inventory_sku ON inventory (company_id, sku);
CREATE INDEX idx_inventory_category ON inventory (company_id, category) WHERE category IS NOT NULL;
CREATE INDEX idx_inventory_location ON inventory (company_id, location) WHERE location IS NOT NULL;
CREATE INDEX idx_inventory_barcode ON inventory (company_id, barcode) WHERE barcode IS NOT NULL;

-- Low stock query optimization
CREATE INDEX idx_inventory_low_stock ON inventory (company_id, quantity, reorder_point) 
    WHERE reorder_point IS NOT NULL AND is_archived = false;

-- Full-text search index
CREATE INDEX idx_inventory_search ON inventory 
    USING GIN (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(sku, '') || ' ' || coalesce(description, '')));

-- Archived items (for cleanup queries)
CREATE INDEX idx_inventory_archived ON inventory (company_id, is_archived, archived_at) 
    WHERE is_archived = true;

CREATE TRIGGER update_inventory_updated_at
    BEFORE UPDATE ON inventory
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- SECTION 4: INVENTORY ADJUSTMENTS TABLE
-- ============================================================================
-- Audit trail for all quantity changes with reasons.

CREATE TABLE IF NOT EXISTS inventory_adjustments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    inventory_id UUID NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
    
    -- Adjustment details
    adjustment_type TEXT NOT NULL 
        CHECK (adjustment_type IN ('add', 'subtract', 'set')),
    amount INTEGER NOT NULL CHECK (amount >= 0),
    
    -- Quantities for audit trail
    previous_quantity INTEGER NOT NULL,
    new_quantity INTEGER NOT NULL,
    
    -- Reason classification
    reason TEXT NOT NULL CHECK (reason IN (
        'received_shipment',
        'returned_item', 
        'damaged_goods',
        'theft_loss',
        'expired',
        'physical_count',
        'transfer_in',
        'transfer_out',
        'production_use',
        'other'
    )),
    
    -- Additional context
    notes TEXT,
    reference TEXT,  -- External reference (PO number, damage report, etc.)
    
    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID NOT NULL REFERENCES auth.users(id)
);

-- Index for item history lookups
CREATE INDEX idx_adjustments_inventory ON inventory_adjustments (inventory_id, created_at DESC);

-- Index for company-wide adjustment reports
CREATE INDEX idx_adjustments_company ON inventory_adjustments (company_id, created_at DESC);

-- Index for reason-based queries
CREATE INDEX idx_adjustments_reason ON inventory_adjustments (company_id, reason, created_at DESC);

-- ============================================================================
-- SECTION 5: IDEMPOTENCY KEYS TABLE
-- ============================================================================
-- Stores API request idempotency keys to prevent duplicate operations.

CREATE TABLE IF NOT EXISTS idempotency_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Key identification (unique per user)
    key TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Cached response
    response_status INTEGER NOT NULL,
    response_body TEXT NOT NULL,
    
    -- TTL management
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
    
    CONSTRAINT unique_key_per_user UNIQUE (key, user_id)
);

-- Fast lookups
CREATE INDEX idx_idempotency_lookup ON idempotency_keys (key, user_id);

-- TTL cleanup
CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);

-- ============================================================================
-- SECTION 6: API RATE LIMITS TABLE (Optional - for distributed rate limiting)
-- ============================================================================
-- For production with multiple Edge Function instances, use database-backed
-- rate limiting instead of in-memory.

CREATE TABLE IF NOT EXISTS rate_limit_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Rate limit key (usually user_id or API key)
    key TEXT NOT NULL,
    
    -- Current window
    request_count INTEGER NOT NULL DEFAULT 1,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Expiration for cleanup
    expires_at TIMESTAMPTZ NOT NULL,
    
    CONSTRAINT unique_rate_limit_key UNIQUE (key)
);

CREATE INDEX idx_rate_limit_key ON rate_limit_entries (key);
CREATE INDEX idx_rate_limit_expires ON rate_limit_entries (expires_at);

-- ============================================================================
-- SECTION 7: ROW LEVEL SECURITY POLICIES
-- ============================================================================
-- 
-- CRITICAL: These policies are the foundation of our security model.
-- They ensure users can ONLY access data belonging to their company.
--
-- The company_id is extracted from the JWT's app_metadata claim.
-- This is set during user registration and cannot be modified by users.
--
-- ============================================================================

-- Helper function to get current user's company_id from JWT
CREATE OR REPLACE FUNCTION get_user_company_id()
RETURNS UUID AS $$
BEGIN
    RETURN (auth.jwt() -> 'app_metadata' ->> 'company_id')::UUID;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Helper function to get current user's role
CREATE OR REPLACE FUNCTION get_user_role()
RETURNS TEXT AS $$
BEGIN
    RETURN (
        SELECT role FROM user_profiles 
        WHERE id = auth.uid() AND is_active = true
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------
-- COMPANIES RLS
-- ----------------------------------------
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;

-- Users can only view their own company
CREATE POLICY "Users can view own company"
    ON companies FOR SELECT
    USING (id = get_user_company_id());

-- Only owners can update company details
CREATE POLICY "Owners can update own company"
    ON companies FOR UPDATE
    USING (id = get_user_company_id() AND get_user_role() = 'owner')
    WITH CHECK (id = get_user_company_id());

-- Companies are created through admin processes, not user API
-- No INSERT policy for regular users

-- ----------------------------------------
-- USER PROFILES RLS
-- ----------------------------------------
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- Users can view profiles in their company
CREATE POLICY "Users can view company profiles"
    ON user_profiles FOR SELECT
    USING (company_id = get_user_company_id());

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
    ON user_profiles FOR UPDATE
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid() AND company_id = get_user_company_id());

-- Admins/owners can manage profiles in their company
CREATE POLICY "Admins can manage company profiles"
    ON user_profiles FOR ALL
    USING (
        company_id = get_user_company_id() 
        AND get_user_role() IN ('owner', 'admin')
    )
    WITH CHECK (company_id = get_user_company_id());

-- ----------------------------------------
-- INVENTORY RLS
-- ----------------------------------------
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;

-- All company users can view inventory
CREATE POLICY "Users can view company inventory"
    ON inventory FOR SELECT
    USING (company_id = get_user_company_id());

-- Members and above can create inventory
CREATE POLICY "Members can create inventory"
    ON inventory FOR INSERT
    WITH CHECK (
        company_id = get_user_company_id()
        AND get_user_role() IN ('owner', 'admin', 'member')
    );

-- Members and above can update inventory
CREATE POLICY "Members can update inventory"
    ON inventory FOR UPDATE
    USING (company_id = get_user_company_id())
    WITH CHECK (
        company_id = get_user_company_id()
        AND get_user_role() IN ('owner', 'admin', 'member')
    );

-- Only admins/owners can delete inventory
CREATE POLICY "Admins can delete inventory"
    ON inventory FOR DELETE
    USING (
        company_id = get_user_company_id()
        AND get_user_role() IN ('owner', 'admin')
    );

-- ----------------------------------------
-- INVENTORY ADJUSTMENTS RLS
-- ----------------------------------------
ALTER TABLE inventory_adjustments ENABLE ROW LEVEL SECURITY;

-- All company users can view adjustments
CREATE POLICY "Users can view company adjustments"
    ON inventory_adjustments FOR SELECT
    USING (company_id = get_user_company_id());

-- Members and above can create adjustments
CREATE POLICY "Members can create adjustments"
    ON inventory_adjustments FOR INSERT
    WITH CHECK (
        company_id = get_user_company_id()
        AND get_user_role() IN ('owner', 'admin', 'member')
    );

-- Adjustments are immutable (audit trail) - no UPDATE policy
-- Adjustments are permanent (audit trail) - no DELETE policy

-- ----------------------------------------
-- IDEMPOTENCY KEYS RLS
-- ----------------------------------------
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;

-- Users can only access their own idempotency keys
CREATE POLICY "Users can manage own idempotency keys"
    ON idempotency_keys FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ----------------------------------------
-- RATE LIMIT ENTRIES RLS
-- ----------------------------------------
ALTER TABLE rate_limit_entries ENABLE ROW LEVEL SECURITY;

-- Rate limits are managed by the system, not users
-- Service role only (no user policies)

-- ============================================================================
-- SECTION 8: DATABASE FUNCTIONS
-- ============================================================================

-- ----------------------------------------
-- Atomic quantity adjustment function
-- ----------------------------------------
-- This function performs quantity adjustments atomically to prevent
-- race conditions in high-concurrency environments.

CREATE OR REPLACE FUNCTION adjust_inventory_quantity(
    p_inventory_id UUID,
    p_adjustment_type TEXT,
    p_amount INTEGER,
    p_reason TEXT,
    p_notes TEXT DEFAULT NULL,
    p_reference TEXT DEFAULT NULL
)
RETURNS TABLE (
    inventory_id UUID,
    previous_quantity INTEGER,
    new_quantity INTEGER,
    adjustment_id UUID
) AS $$
DECLARE
    v_company_id UUID;
    v_previous_quantity INTEGER;
    v_new_quantity INTEGER;
    v_adjustment_id UUID;
BEGIN
    -- Get current state with row lock
    SELECT i.company_id, i.quantity
    INTO v_company_id, v_previous_quantity
    FROM inventory i
    WHERE i.id = p_inventory_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory item not found';
    END IF;
    
    -- Verify user has access to this company
    IF v_company_id != get_user_company_id() THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    -- Calculate new quantity
    CASE p_adjustment_type
        WHEN 'add' THEN
            v_new_quantity := v_previous_quantity + p_amount;
        WHEN 'subtract' THEN
            v_new_quantity := v_previous_quantity - p_amount;
            IF v_new_quantity < 0 THEN
                RAISE EXCEPTION 'Adjustment would result in negative quantity';
            END IF;
        WHEN 'set' THEN
            v_new_quantity := p_amount;
        ELSE
            RAISE EXCEPTION 'Invalid adjustment type: %', p_adjustment_type;
    END CASE;
    
    -- Update inventory
    UPDATE inventory
    SET quantity = v_new_quantity,
        updated_at = NOW(),
        updated_by = auth.uid()
    WHERE id = p_inventory_id;
    
    -- Create adjustment record
    INSERT INTO inventory_adjustments (
        company_id,
        inventory_id,
        adjustment_type,
        amount,
        previous_quantity,
        new_quantity,
        reason,
        notes,
        reference,
        created_by
    ) VALUES (
        v_company_id,
        p_inventory_id,
        p_adjustment_type,
        p_amount,
        v_previous_quantity,
        v_new_quantity,
        p_reason,
        p_notes,
        p_reference,
        auth.uid()
    )
    RETURNING id INTO v_adjustment_id;
    
    -- Return results
    RETURN QUERY SELECT p_inventory_id, v_previous_quantity, v_new_quantity, v_adjustment_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------
-- Low stock items function
-- ----------------------------------------
-- Returns items where quantity <= reorder_point with urgency classification.

CREATE OR REPLACE FUNCTION get_low_stock_items(
    p_category TEXT DEFAULT NULL,
    p_location TEXT DEFAULT NULL,
    p_include_zero BOOLEAN DEFAULT TRUE,
    p_urgency TEXT DEFAULT 'all',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    sku TEXT,
    quantity INTEGER,
    reorder_point INTEGER,
    reorder_quantity INTEGER,
    deficit INTEGER,
    urgency TEXT,
    category TEXT,
    location TEXT,
    supplier TEXT,
    unit_cost DECIMAL(12, 2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.sku,
        i.quantity,
        i.reorder_point,
        i.reorder_quantity,
        (i.reorder_point - i.quantity) AS deficit,
        CASE 
            WHEN i.quantity = 0 THEN 'critical'
            WHEN i.quantity <= (i.reorder_point * 0.25) THEN 'critical'
            ELSE 'warning'
        END AS urgency,
        i.category,
        i.location,
        i.supplier,
        i.unit_cost
    FROM inventory i
    WHERE 
        i.company_id = get_user_company_id()
        AND i.is_archived = FALSE
        AND i.reorder_point IS NOT NULL
        AND i.quantity <= i.reorder_point
        AND (p_include_zero OR i.quantity > 0)
        AND (p_category IS NULL OR i.category = p_category)
        AND (p_location IS NULL OR i.location ILIKE '%' || p_location || '%')
        AND (p_urgency = 'all' OR 
             (p_urgency = 'critical' AND (i.quantity = 0 OR i.quantity <= (i.reorder_point * 0.25))) OR
             (p_urgency = 'warning' AND i.quantity > (i.reorder_point * 0.25)))
    ORDER BY 
        i.quantity ASC,  -- Zero first
        (i.reorder_point - i.quantity) DESC,  -- Most urgent deficit
        i.name ASC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------
-- Full-text search function
-- ----------------------------------------
-- Searches across name, SKU, and description with relevance ranking.

CREATE OR REPLACE FUNCTION search_inventory(
    p_search_query TEXT,
    p_category TEXT DEFAULT NULL,
    p_location TEXT DEFAULT NULL,
    p_include_archived BOOLEAN DEFAULT FALSE,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    sku TEXT,
    description TEXT,
    quantity INTEGER,
    category TEXT,
    location TEXT,
    is_archived BOOLEAN,
    rank REAL
) AS $$
DECLARE
    v_tsquery tsquery;
BEGIN
    -- Convert search query to tsquery with prefix matching
    v_tsquery := plainto_tsquery('english', p_search_query);
    
    RETURN QUERY
    SELECT 
        i.id,
        i.name,
        i.sku,
        i.description,
        i.quantity,
        i.category,
        i.location,
        i.is_archived,
        ts_rank(
            to_tsvector('english', coalesce(i.name, '') || ' ' || coalesce(i.sku, '') || ' ' || coalesce(i.description, '')),
            v_tsquery
        ) AS rank
    FROM inventory i
    WHERE 
        i.company_id = get_user_company_id()
        AND (p_include_archived OR i.is_archived = FALSE)
        AND (p_category IS NULL OR i.category = p_category)
        AND (p_location IS NULL OR i.location ILIKE '%' || p_location || '%')
        AND (
            to_tsvector('english', coalesce(i.name, '') || ' ' || coalesce(i.sku, '') || ' ' || coalesce(i.description, '')) @@ v_tsquery
            OR i.sku ILIKE '%' || p_search_query || '%'
            OR i.barcode = p_search_query
        )
    ORDER BY rank DESC, i.name ASC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- SECTION 9: SCHEDULED JOBS (via pg_cron or external scheduler)
-- ============================================================================

-- These are SQL statements to be run periodically, not triggers.
-- Configure via Supabase Dashboard > Database > Extensions > pg_cron
-- Or use an external scheduler like GitHub Actions, AWS EventBridge, etc.

-- Cleanup expired idempotency keys (run daily)
-- DELETE FROM idempotency_keys WHERE expires_at < NOW();

-- Cleanup expired rate limit entries (run every 5 minutes)
-- DELETE FROM rate_limit_entries WHERE expires_at < NOW();

-- Archive old adjustments to cold storage (run monthly) - future enhancement
-- This would move adjustments older than 2 years to an archive table

-- ============================================================================
-- SECTION 10: GRANTS FOR SUPABASE
-- ============================================================================
-- Supabase automatically handles most grants, but these ensure the anon
-- and authenticated roles can access our functions.

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT INSERT, UPDATE, DELETE ON inventory TO authenticated;
GRANT INSERT ON inventory_adjustments TO authenticated;
GRANT ALL ON idempotency_keys TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_company_id() TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION adjust_inventory_quantity TO authenticated;
GRANT EXECUTE ON FUNCTION get_low_stock_items TO authenticated;
GRANT EXECUTE ON FUNCTION search_inventory TO authenticated;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
