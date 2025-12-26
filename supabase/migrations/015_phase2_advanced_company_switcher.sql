-- Phase 2: advanced company switcher (super user only)
-- Feature IDs: inventory.auth.company_switcher, inventory.audit.company_switch

BEGIN;

-- Expand audit log action whitelist to include company switch events
ALTER TABLE public.audit_log
    DROP CONSTRAINT IF EXISTS audit_log_action_check;

ALTER TABLE public.audit_log
    ADD CONSTRAINT audit_log_action_check
    CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'RESTORE', 'BULK_DELETE', 'ROLLBACK', 'PERMANENT_PURGE', 'COMPANY_SWITCH'));

-- Update get_my_companies to include company_type for environment badges
DROP FUNCTION IF EXISTS public.get_my_companies(BOOLEAN);
CREATE OR REPLACE FUNCTION public.get_my_companies(p_include_non_production BOOLEAN DEFAULT false)
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    company_type TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_include_non_production BOOLEAN := COALESCE(p_include_non_production, false);
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
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state,
            c.company_type::text
        FROM public.companies c
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE c.is_active = true
          AND (c.company_type = 'production' OR v_include_non_production)
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
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state,
            c.company_type::text
        FROM public.companies c
        JOIN public.company_members cm ON cm.company_id = c.id
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE cm.user_id = auth.uid()
          AND c.is_active = true
          AND c.company_type = 'production'
        ORDER BY c.name;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_companies(BOOLEAN) TO authenticated;

-- Advanced company switcher search (super user only)
CREATE OR REPLACE FUNCTION public.get_company_switcher_companies(
    p_search TEXT DEFAULT NULL,
    p_company_type TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    company_type TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_search TEXT := NULLIF(trim(COALESCE(p_search, '')), '');
    v_type TEXT := NULLIF(trim(lower(COALESCE(p_company_type, ''))), '');
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Super user access required';
    END IF;

    IF v_type IS NOT NULL AND v_type NOT IN ('production','sandbox','test','system') THEN
        RAISE EXCEPTION 'Invalid company_type';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.slug,
        'super_user'::text,
        true,
        (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
        tier.effective_tier,
        tier.tier_source,
        tier.billing_state,
        c.company_type::text
    FROM public.companies c
    CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
    WHERE c.is_active = true
      AND (v_type IS NULL OR c.company_type::text = v_type)
      AND (
        v_search IS NULL
        OR c.id::text = v_search
        OR c.name ILIKE '%' || v_search || '%'
        OR c.slug ILIKE '%' || v_search || '%'
      )
    ORDER BY c.name
    LIMIT v_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_switcher_companies(TEXT, TEXT, INTEGER) TO authenticated;

-- Audit log entry for super user company switches
CREATE OR REPLACE FUNCTION public.log_company_switch(
    p_company_id UUID,
    p_from_company_id UUID DEFAULT NULL,
    p_from_company_type TEXT DEFAULT NULL,
    p_to_company_type TEXT DEFAULT NULL,
    p_source TEXT DEFAULT 'advanced_switcher'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_from_type TEXT := NULLIF(trim(lower(COALESCE(p_from_company_type, ''))), '');
    v_to_type TEXT := NULLIF(trim(lower(COALESCE(p_to_company_type, ''))), '');
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    IF p_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    INSERT INTO public.audit_log (
        action, table_name, record_id, company_id, user_id, reason, new_values
    ) VALUES (
        'COMPANY_SWITCH',
        'companies',
        p_company_id,
        p_company_id,
        auth.uid(),
        'Advanced company switcher',
        jsonb_build_object(
            'from_company_id', p_from_company_id,
            'from_company_type', v_from_type,
            'to_company_type', v_to_type,
            'source', NULLIF(trim(COALESCE(p_source, '')), '')
        )
    );

    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_company_switch(UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;

COMMIT;
