-- Fix seed_company_inventory function overloading issue
-- PostgREST may have trouble with overloaded functions
-- Remove the 4-parameter wrapper and rely solely on the 5-parameter version with default

-- Drop the 4-parameter overload wrapper
DROP FUNCTION IF EXISTS public.seed_company_inventory(UUID, UUID, TEXT, TEXT);

-- Re-grant execute on the remaining 5-parameter version
GRANT EXECUTE ON FUNCTION public.seed_company_inventory(UUID, UUID, TEXT, TEXT, TEXT[]) TO authenticated;

-- Force schema reload
NOTIFY pgrst, 'reload schema';
