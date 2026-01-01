BEGIN;

DROP FUNCTION IF EXISTS public.get_company_switcher_companies(TEXT, TEXT, INTEGER);

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
    inventory_count BIGINT,
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
        (SELECT COUNT(*) FROM public.inventory_items i WHERE i.company_id = c.id AND i.deleted_at IS NULL),
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

COMMIT;
