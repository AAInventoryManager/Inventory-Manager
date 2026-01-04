-- Add RLS policies to company_locations table

BEGIN;

ALTER TABLE public.company_locations ENABLE ROW LEVEL SECURITY;

-- Select: users can only see locations for companies they belong to
DROP POLICY IF EXISTS "company_locations_select" ON public.company_locations;
CREATE POLICY "company_locations_select"
    ON public.company_locations FOR SELECT
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

-- Insert: users can only create locations for companies they belong to (with permission)
DROP POLICY IF EXISTS "company_locations_insert" ON public.company_locations;
CREATE POLICY "company_locations_insert"
    ON public.company_locations FOR INSERT
    TO authenticated
    WITH CHECK (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

-- Update: users can only update locations for companies they belong to (with permission)
DROP POLICY IF EXISTS "company_locations_update" ON public.company_locations;
CREATE POLICY "company_locations_update"
    ON public.company_locations FOR UPDATE
    TO authenticated
    USING (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

-- Delete: users can only delete locations for companies they belong to (with permission)
DROP POLICY IF EXISTS "company_locations_delete" ON public.company_locations;
CREATE POLICY "company_locations_delete"
    ON public.company_locations FOR DELETE
    TO authenticated
    USING (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

COMMIT;
