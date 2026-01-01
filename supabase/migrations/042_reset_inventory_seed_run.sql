BEGIN;

CREATE OR REPLACE FUNCTION public.reset_inventory_seed_run(
    p_target_company_id UUID
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted INTEGER := 0;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_target_company_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Target company required');
    END IF;

    DELETE FROM public.inventory_seed_runs
    WHERE target_company_id = p_target_company_id;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN json_build_object('success', true, 'deleted', v_deleted);
END;
$$;

GRANT EXECUTE ON FUNCTION public.reset_inventory_seed_run(UUID) TO authenticated;

COMMIT;
