-- Set all companies to demo except Oakley Services

BEGIN;

UPDATE public.companies
SET environment_type = 'demo';

UPDATE public.companies
SET environment_type = 'production'
WHERE lower(COALESCE(name, '')) = 'oakley services'
   OR lower(COALESCE(slug, '')) = 'oakley-services';

COMMIT;
