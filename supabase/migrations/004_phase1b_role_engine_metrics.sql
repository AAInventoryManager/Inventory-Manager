-- Phase 1B: role engine, metrics, and tier gating
-- Feature IDs: inventory.auth.roles, inventory.metrics.dashboard, inventory.snapshots.ui

-- Company tier helper (defaults to starter when missing)
CREATE OR REPLACE FUNCTION public.get_company_tier(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_tier TEXT;
BEGIN
    SELECT lower(trim(settings->>'tier'))
    INTO v_tier
    FROM public.companies
    WHERE id = p_company_id;

    IF v_tier IS NULL OR v_tier = '' THEN
        RETURN 'starter';
    END IF;

    IF v_tier NOT IN ('starter','professional','business','enterprise') THEN
        RETURN 'starter';
    END IF;

    RETURN v_tier;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier(UUID) TO authenticated;

-- Update get_my_companies to include company_tier
DROP FUNCTION IF EXISTS public.get_my_companies();
CREATE OR REPLACE FUNCTION public.get_my_companies()
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    company_tier TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF public.is_super_user() THEN
        RETURN QUERY
        SELECT 
            c.id,
            c.name,
            c.slug,
            'super_user'::text,
            true,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            public.get_company_tier(c.id)
        FROM public.companies c
        WHERE c.is_active = true
        ORDER BY c.name;
    ELSE
        RETURN QUERY
        SELECT 
            c.id,
            c.name,
            c.slug,
            cm.role,
            cm.is_super_user,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            public.get_company_tier(c.id)
        FROM public.companies c
        JOIN public.company_members cm ON cm.company_id = c.id
        WHERE cm.user_id = auth.uid()
        AND c.is_active = true
        ORDER BY c.name;
    END IF;
END;
$$;

-- Role engine permissions (inventory.auth.roles)
UPDATE public.role_configurations
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

UPDATE public.role_configurations
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

UPDATE public.role_configurations
SET permissions = '{
    "items:view": true,
    "items:export": true,
    "orders:view": true,
    "members:view": true
}'::jsonb,
    updated_at = now()
WHERE role_name = 'viewer';

-- Permission check RPC (inventory.auth.roles)
CREATE OR REPLACE FUNCTION public.check_permission(
    p_company_id UUID,
    p_permission_key TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_role TEXT;
    v_has_permission BOOLEAN;
BEGIN
    IF p_company_id IS NULL OR p_permission_key IS NULL OR length(trim(p_permission_key)) = 0 THEN
        RETURN false;
    END IF;

    IF public.is_super_user() THEN
        RETURN true;
    END IF;

    SELECT role
    INTO v_role
    FROM public.company_members
    WHERE company_id = p_company_id
      AND user_id = auth.uid();

    IF v_role IS NULL THEN
        RETURN false;
    END IF;

    SELECT (rc.permissions->>p_permission_key)::boolean
    INTO v_has_permission
    FROM public.role_configurations rc
    WHERE rc.role_name = v_role;

    RETURN COALESCE(v_has_permission, false);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_permission(UUID, TEXT) TO authenticated;

-- Get user permissions (inventory.auth.roles)
CREATE OR REPLACE FUNCTION public.get_user_permissions(
    p_company_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_role TEXT;
    v_permissions JSONB;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;

    IF public.is_super_user() THEN
        RETURN '{
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
            "snapshots:view": true,
            "platform:view_all_companies": true,
            "platform:manage_roles": true,
            "platform:view_metrics": true
        }'::jsonb;
    END IF;

    SELECT role
    INTO v_role
    FROM public.company_members
    WHERE company_id = p_company_id
      AND user_id = auth.uid();

    IF v_role IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;

    SELECT rc.permissions
    INTO v_permissions
    FROM public.role_configurations rc
    WHERE rc.role_name = v_role;

    RETURN COALESCE(v_permissions, '{}'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_permissions(UUID) TO authenticated;

-- Snapshots list with tier gate (inventory.snapshots.ui)
CREATE OR REPLACE FUNCTION public.get_snapshots(p_company_id UUID)
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    snapshot_type TEXT,
    items_count INTEGER,
    total_quantity INTEGER,
    created_at TIMESTAMPTZ,
    created_by_email TEXT,
    was_restored BOOLEAN,
    restored_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (public.is_super_user() OR public.user_can_delete(p_company_id)) THEN 
        RETURN; 
    END IF;

    IF public.get_company_tier(p_company_id) NOT IN ('business','enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    RETURN QUERY
    SELECT s.id, s.name, s.description, s.snapshot_type, s.items_count, s.total_quantity,
        s.created_at, u.email, (s.restored_at IS NOT NULL), s.restored_at
    FROM public.inventory_snapshots s
    LEFT JOIN auth.users u ON u.id = s.created_by
    WHERE s.company_id = p_company_id
    ORDER BY s.created_at DESC;
END;
$$;

-- Metrics dashboard RPCs (inventory.metrics.dashboard)
CREATE OR REPLACE FUNCTION public.get_company_dashboard_metrics(
    p_company_id UUID,
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_days INTEGER;
    v_result JSONB;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Company required';
    END IF;

    IF public.get_company_tier(p_company_id) NOT IN ('professional','business','enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(p_company_id, 'metrics:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_days := GREATEST(COALESCE(p_days, 30), 1);

    SELECT jsonb_build_object(
        'current', jsonb_build_object(
            'total_items', (
                SELECT COUNT(*) FROM public.inventory_items
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'total_quantity', (
                SELECT COALESCE(SUM(quantity), 0) FROM public.inventory_items
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'low_stock_count', (
                SELECT COUNT(*) FROM public.inventory_items
                WHERE company_id = p_company_id
                  AND deleted_at IS NULL
                  AND low_stock_qty IS NOT NULL
                  AND quantity <= low_stock_qty
            ),
            'active_members', (
                SELECT COUNT(*) FROM public.company_members
                WHERE company_id = p_company_id
            ),
            'snapshot_count', (
                SELECT COUNT(*) FROM public.inventory_snapshots
                WHERE company_id = p_company_id
            )
        ),
        'activity', (
            SELECT jsonb_build_object(
                'total_updates', COALESCE(SUM(CASE WHEN action_type = 'update' THEN action_count ELSE 0 END), 0),
                'total_deletes', COALESCE(SUM(CASE WHEN action_type IN ('delete','bulk_delete') THEN action_count ELSE 0 END), 0),
                'total_restores', COALESCE(SUM(CASE WHEN action_type = 'restore' THEN action_count ELSE 0 END), 0),
                'total_rollbacks', COALESCE(SUM(CASE WHEN action_type = 'rollback' THEN action_count ELSE 0 END), 0),
                'records_affected', COALESCE(SUM(records_affected), 0),
                'quantity_removed', COALESCE(SUM(quantity_removed), 0),
                'quantity_added', COALESCE(SUM(quantity_added), 0)
            )
            FROM public.action_metrics
            WHERE company_id = p_company_id
              AND metric_date >= CURRENT_DATE - v_days
        ),
        'daily', (
            SELECT COALESCE(jsonb_agg(d ORDER BY d.metric_date DESC), '[]'::jsonb)
            FROM (
                SELECT metric_date,
                    action_type,
                    SUM(action_count) AS action_count,
                    SUM(records_affected) AS records_affected
                FROM public.action_metrics
                WHERE company_id = p_company_id
                  AND metric_date >= CURRENT_DATE - v_days
                GROUP BY metric_date, action_type
            ) d
        ),
        'top_users', (
            SELECT COALESCE(jsonb_agg(u), '[]'::jsonb)
            FROM (
                SELECT am.user_id,
                    p.email,
                    SUM(am.action_count) AS total_actions
                FROM public.action_metrics am
                LEFT JOIN public.profiles p ON p.user_id = am.user_id
                WHERE am.company_id = p_company_id
                  AND am.metric_date >= CURRENT_DATE - v_days
                GROUP BY am.user_id, p.email
                ORDER BY total_actions DESC
                LIMIT 5
            ) u
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_platform_dashboard_metrics(
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_days INTEGER;
    v_result JSONB;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_days := GREATEST(COALESCE(p_days, 30), 1);

    SELECT jsonb_build_object(
        'platform', jsonb_build_object(
            'total_companies', (SELECT COUNT(*) FROM public.companies),
            'total_users', (SELECT COUNT(DISTINCT user_id) FROM public.company_members),
            'total_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NULL),
            'total_orders', (SELECT COUNT(*) FROM public.orders WHERE deleted_at IS NULL)
        ),
        'activity', jsonb_build_object(
            'total_actions', (
                SELECT COALESCE(SUM(action_count), 0)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            ),
            'active_companies', (
                SELECT COUNT(DISTINCT company_id)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            ),
            'active_users', (
                SELECT COUNT(DISTINCT user_id)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            )
        ),
        'companies', (
            SELECT COALESCE(jsonb_agg(c), '[]'::jsonb)
            FROM (
                SELECT co.id,
                    co.name,
                    (SELECT COUNT(*) FROM public.company_members cm WHERE cm.company_id = co.id) AS member_count,
                    (SELECT COUNT(*) FROM public.inventory_items ii WHERE ii.company_id = co.id AND ii.deleted_at IS NULL) AS item_count,
                    COALESCE((
                        SELECT SUM(action_count) FROM public.action_metrics am
                        WHERE am.company_id = co.id
                          AND am.metric_date >= CURRENT_DATE - v_days
                    ), 0) AS recent_actions
                FROM public.companies co
                ORDER BY recent_actions DESC
                LIMIT 20
            ) c
        ),
        'daily', (
            SELECT COALESCE(jsonb_agg(d ORDER BY d.metric_date DESC), '[]'::jsonb)
            FROM (
                SELECT metric_date,
                    SUM(action_count) AS total_actions,
                    COUNT(DISTINCT company_id) AS active_companies
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
                GROUP BY metric_date
            ) d
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_dashboard_metrics(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_platform_dashboard_metrics(INTEGER) TO authenticated;
