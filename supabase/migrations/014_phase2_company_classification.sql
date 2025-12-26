-- Phase 2: company classification for UI governance
-- Feature IDs: inventory.governance.company_type, inventory.auth.company_selector

BEGIN;

-- Company type enum for explicit classification
DO $$
BEGIN
    CREATE TYPE public.company_type AS ENUM ('production','sandbox','test','system');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS company_type public.company_type NOT NULL DEFAULT 'production';

COMMENT ON COLUMN public.companies.company_type IS 'Company classification: production, sandbox, test, system';

-- Backfill test companies by name (explicit governance rule)
UPDATE public.companies
SET company_type = 'test'
WHERE name ILIKE '%test%'
   OR name ILIKE '%fixture%'
   OR name ILIKE '%mock%'
   OR name ILIKE '%ci%';

-- Backfill known internal/platform companies (explicit list)
UPDATE public.companies
SET company_type = 'system'
WHERE slug IN ('modulus-software', 'inventory-manager');

-- Update get_my_companies to default UI selectors to production companies only
DROP FUNCTION IF EXISTS public.get_my_companies();
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
    billing_state TEXT
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
            tier.billing_state
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
            tier.billing_state
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

COMMIT;
