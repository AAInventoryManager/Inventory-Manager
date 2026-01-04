-- Drop legacy receipt RPC overloads to avoid PostgREST ambiguity

BEGIN;

DROP FUNCTION IF EXISTS public.create_receipt(UUID, UUID);

NOTIFY pgrst, 'reload schema';

COMMIT;
