-- Phase 1 remediation: metrics & reporting entitlements
-- Feature IDs: inventory.metrics.dashboard, inventory.metrics.action_metrics, inventory.metrics.platform_summary,
--              inventory.reports.inventory, inventory.reports.low_stock_api

-- Action metrics RLS: restrict to professional+ tier for super users
DROP POLICY IF EXISTS "Super users can view metrics" ON public.action_metrics;
DROP POLICY IF EXISTS "Metrics access" ON public.action_metrics;
CREATE POLICY "Metrics access"
    ON public.action_metrics FOR SELECT
    USING (
        public.is_super_user()
        AND public.get_company_tier(company_id) IN ('professional','business','enterprise')
    );

-- Platform metrics RPC: enforce tier
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

    IF NOT EXISTS (
        SELECT 1
        FROM public.company_members cm
        JOIN public.companies c ON c.id = cm.company_id
        WHERE cm.user_id = auth.uid()
          AND public.get_company_tier(c.id) IN ('professional','business','enterprise')
    ) THEN
        RETURN json_build_object('error', 'Feature not available for current plan');
    END IF;

    RETURN json_build_object(
        'total_companies', (SELECT COUNT(*) FROM public.companies),
        'active_companies', (SELECT COUNT(*) FROM public.companies WHERE is_active = true),
        'total_users', (SELECT COUNT(*) FROM auth.users),
        'total_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NULL),
        'total_deleted_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NOT NULL),
        'companies_breakdown', (
            SELECT json_agg(row_to_json(t))
            FROM (
                SELECT 
                    c.name,
                    (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id) as users,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NULL) as items,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NOT NULL) as deleted_items
                FROM public.companies c WHERE c.is_active = true
            ) t
        )
    );
END;
$$;

-- Action metrics RPC: enforce tier
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

    IF p_company_id IS NOT NULL THEN
        IF public.get_company_tier(p_company_id) NOT IN ('professional','business','enterprise') THEN
            RETURN json_build_object('error', 'Feature not available for current plan');
        END IF;
    ELSE
        IF NOT EXISTS (
            SELECT 1
            FROM public.company_members cm
            JOIN public.companies c ON c.id = cm.company_id
            WHERE cm.user_id = auth.uid()
              AND public.get_company_tier(c.id) IN ('professional','business','enterprise')
        ) THEN
            RETURN json_build_object('error', 'Feature not available for current plan');
        END IF;
    END IF;

    RETURN json_build_object(
        'period_days', p_days,
        'total_deletes', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'delete'),
        'total_updates', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'update'),
        'total_restores', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'restore'),
        'quantity_removed', (SELECT COALESCE(SUM(quantity_removed), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days)
    );
END;
$$;

-- Low stock report RPC (edge API dependency)
CREATE OR REPLACE FUNCTION public.get_low_stock_items(
    p_category TEXT DEFAULT NULL,
    p_location TEXT DEFAULT NULL,
    p_include_zero BOOLEAN DEFAULT true,
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
    unit_cost NUMERIC,
    supplier TEXT,
    last_reorder_date TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_limit INTEGER;
    v_offset INTEGER;
BEGIN
    v_company_id := public.get_user_company_id();
    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'Company required';
    END IF;

    IF public.get_company_tier(v_company_id) NOT IN ('professional','business','enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(v_company_id, 'items:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_limit := GREATEST(COALESCE(p_limit, 50), 1);
    v_offset := GREATEST(COALESCE(p_offset, 0), 0);

    RETURN QUERY
    SELECT
        i.id,
        i.name,
        i.sku,
        i.quantity,
        COALESCE(i.reorder_point, i.low_stock_qty) AS reorder_point,
        i.reorder_quantity,
        GREATEST(COALESCE(i.reorder_point, i.low_stock_qty) - i.quantity, 0) AS deficit,
        CASE WHEN i.quantity <= 0 THEN 'critical' ELSE 'warning' END AS urgency,
        c.name AS category,
        l.name AS location,
        i.unit_cost,
        NULL::text AS supplier,
        NULL::timestamptz AS last_reorder_date
    FROM public.inventory_items i
    LEFT JOIN public.inventory_categories c ON c.id = i.category_id AND c.deleted_at IS NULL
    LEFT JOIN public.inventory_locations l ON l.id = i.location_id AND l.deleted_at IS NULL
    WHERE i.company_id = v_company_id
      AND i.deleted_at IS NULL
      AND COALESCE(i.reorder_point, i.low_stock_qty) IS NOT NULL
      AND i.quantity <= COALESCE(i.reorder_point, i.low_stock_qty)
      AND (p_include_zero OR i.quantity > 0)
      AND (p_category IS NULL OR c.name ILIKE ('%' || p_category || '%'))
      AND (p_location IS NULL OR l.name ILIKE ('%' || p_location || '%'))
      AND (
        p_urgency IS NULL
        OR p_urgency = 'all'
        OR (p_urgency = 'critical' AND i.quantity <= 0)
        OR (p_urgency = 'warning' AND i.quantity > 0)
      )
    ORDER BY
        CASE WHEN i.quantity <= 0 THEN 0 ELSE 1 END,
        (COALESCE(i.reorder_point, i.low_stock_qty) - i.quantity) DESC,
        i.name
    LIMIT v_limit OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_low_stock_items(TEXT, TEXT, BOOLEAN, TEXT, INTEGER, INTEGER) TO authenticated;
