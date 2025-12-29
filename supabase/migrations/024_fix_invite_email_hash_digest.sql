-- Ensure pgcrypto digest resolves via extensions schema for invite email hashing
-- Feature IDs: inventory.auth.invite_lifecycle

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Recreate helper: deterministic, one-way email hash for analytics (no PII).
CREATE OR REPLACE FUNCTION public.hash_invite_email(p_email TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
    SELECT CASE
        WHEN p_email IS NULL THEN NULL
        ELSE encode(extensions.digest(lower(trim(p_email))::bytea, 'sha256'), 'hex')
    END;
$$;

COMMIT;
