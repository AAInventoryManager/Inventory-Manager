-- Backfill environment_type based on existing company_type (explicit classification)

BEGIN;

UPDATE public.companies
SET environment_type = CASE
  WHEN company_type::text = 'sandbox' THEN 'sandbox'
  WHEN company_type::text = 'test' THEN 'internal_test'
  WHEN company_type::text = 'system' THEN 'internal_test'
  ELSE 'production'
END
WHERE environment_type = 'production'
  AND company_type::text <> 'production';

COMMIT;
