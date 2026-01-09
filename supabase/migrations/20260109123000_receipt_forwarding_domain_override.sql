-- Add company receipt forwarding domain overrides and expose settings in get_my_companies.

BEGIN;

DROP FUNCTION IF EXISTS public.get_my_companies();

CREATE OR REPLACE FUNCTION public.get_my_companies()
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    settings JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    -- Super user sees ALL companies
    IF public.is_super_user() THEN
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            'super_user'::text,
            true,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            c.settings
        FROM public.companies c
        WHERE c.is_active = true
        ORDER BY c.name;
    ELSE
        -- Regular users see only their company
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            cm.role,
            cm.is_super_user,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            c.settings
        FROM public.companies c
        JOIN public.company_members cm ON cm.company_id = c.id
        WHERE cm.user_id = auth.uid()
        AND c.is_active = true
        ORDER BY c.name;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_companies() TO authenticated;

UPDATE public.companies
SET settings = COALESCE(settings, '{}'::jsonb)
  || jsonb_build_object('receipt_forward_domain', 'inbound.inventorymanager.app')
WHERE slug = 'oakley-services';

COMMIT;
