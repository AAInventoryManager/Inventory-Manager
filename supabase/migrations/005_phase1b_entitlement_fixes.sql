-- Phase 1B entitlement fixes
-- Feature IDs: inventory.snapshots.ui, inventory.metrics.dashboard, inventory.auth.roles

-- Company tier helper (defaults to starter when missing/invalid)
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

-- Enforce tier + permission for snapshot visibility
DROP POLICY IF EXISTS "Admins can view snapshots" ON public.inventory_snapshots;
CREATE POLICY "Admins can view snapshots"
    ON public.inventory_snapshots FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND (
            public.check_permission(company_id, 'snapshots:view')
            OR public.user_can_delete(company_id)
        )
    );

-- Snapshots list with tier + permission gate (inventory.snapshots.ui)
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
    IF public.get_company_tier(p_company_id) NOT IN ('business','enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT (
        public.check_permission(p_company_id, 'snapshots:view')
        OR public.user_can_delete(p_company_id)
    ) THEN
        RAISE EXCEPTION 'Permission denied';
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

-- Enforce tier for role configuration updates (inventory.auth.roles)
DROP POLICY IF EXISTS "Super users can update role configs" ON public.role_configurations;
CREATE POLICY "Super users can update role configs"
    ON public.role_configurations FOR UPDATE
    USING (
        public.is_super_user()
        AND EXISTS (
            SELECT 1
            FROM public.company_members cm
            JOIN public.companies c ON c.id = cm.company_id
            WHERE cm.user_id = auth.uid()
              AND public.get_company_tier(c.id) IN ('business','enterprise')
        )
    )
    WITH CHECK (
        public.is_super_user()
        AND EXISTS (
            SELECT 1
            FROM public.company_members cm
            JOIN public.companies c ON c.id = cm.company_id
            WHERE cm.user_id = auth.uid()
              AND public.get_company_tier(c.id) IN ('business','enterprise')
        )
    );

-- Metrics dashboard RPCs tier gate (inventory.metrics.dashboard)
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

    IF NOT EXISTS (
        SELECT 1
        FROM public.company_members cm
        JOIN public.companies c ON c.id = cm.company_id
        WHERE cm.user_id = auth.uid()
          AND public.get_company_tier(c.id) IN ('professional','business','enterprise')
    ) THEN
        RAISE EXCEPTION 'Feature not available for current plan';
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
