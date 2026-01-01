-- Allow multi-company membership (super_user/test users)
BEGIN;

ALTER TABLE public.company_members
  DROP CONSTRAINT IF EXISTS company_members_user_id_key;

COMMENT ON TABLE public.company_members IS 'Links users to companies with roles.';

COMMIT;
