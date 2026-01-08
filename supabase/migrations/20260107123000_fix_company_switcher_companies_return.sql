-- Fix get_company_switcher_companies return casting for PostgREST

BEGIN;

DROP FUNCTION IF EXISTS public.get_company_switcher_companies(TEXT, TEXT, INTEGER, TEXT);

CREATE OR REPLACE FUNCTION public.get_company_switcher_companies(
    p_search TEXT DEFAULT NULL,
    p_company_type TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50,
    p_environment_type TEXT DEFAULT NULL
)
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    inventory_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    company_type TEXT,
    environment_type TEXT,
    cleanup_eligible BOOLEAN,
    created_at TIMESTAMPTZ,
    job_count BIGINT,
    po_count BIGINT,
    total_on_hand NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_search TEXT := NULLIF(trim(COALESCE(p_search, '')), '');
    v_type TEXT := NULLIF(trim(lower(COALESCE(p_company_type, ''))), '');
    v_env TEXT := NULLIF(trim(lower(COALESCE(p_environment_type, ''))), '');
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Super user access required';
    END IF;

    IF v_type IS NOT NULL AND v_type NOT IN ('production','sandbox','test','system') THEN
        RAISE EXCEPTION 'Invalid company_type';
    END IF;

    IF v_env IS NOT NULL AND v_env NOT IN ('production','internal_test','demo','sandbox') THEN
        RAISE EXCEPTION 'Invalid environment_type';
    END IF;

    RETURN QUERY
    SELECT
        c.id::uuid,
        c.name::text,
        c.slug::text,
        'super_user'::text,
        true::boolean,
        (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id)::bigint,
        (SELECT COUNT(*) FROM public.inventory_items i WHERE i.company_id = c.id AND i.deleted_at IS NULL)::bigint,
        tier.effective_tier::text,
        tier.tier_source::text,
        tier.billing_state::text,
        c.company_type::text,
        c.environment_type::text,
        c.cleanup_eligible::boolean,
        c.created_at::timestamptz,
        (SELECT COUNT(*) FROM public.jobs j WHERE j.company_id = c.id)::bigint,
        (SELECT COUNT(*) FROM public.purchase_orders po WHERE po.company_id = c.id)::bigint,
        (SELECT COALESCE(SUM(COALESCE(i.quantity, 0)), 0)::numeric
         FROM public.inventory_items i
         WHERE i.company_id = c.id AND i.deleted_at IS NULL)
    FROM public.companies c
    CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
    WHERE c.is_active = true
      AND (v_type IS NULL OR c.company_type::text = v_type)
      AND (v_env IS NULL OR c.environment_type::text = v_env)
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

GRANT EXECUTE ON FUNCTION public.get_company_switcher_companies(TEXT, TEXT, INTEGER, TEXT) TO authenticated;

COMMIT;
