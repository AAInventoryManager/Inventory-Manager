-- Sync environment_type to match company_type for any mismatched companies
-- company_type is the authoritative field that controls destructive actions

BEGIN;

-- Update environment_type to match company_type where they differ
UPDATE public.companies
SET environment_type = company_type::text,
    updated_at = now()
WHERE environment_type IS DISTINCT FROM company_type::text;

COMMIT;
