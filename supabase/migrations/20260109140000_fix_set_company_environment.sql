-- Fix set_company_environment to update both company_type and environment_type
-- The UI displays environment_type but the function was only updating company_type

BEGIN;

CREATE OR REPLACE FUNCTION public.set_company_environment(
    p_company_id UUID,
    p_environment TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_env TEXT := lower(trim(COALESCE(p_environment, '')));
    v_prev TEXT;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company id required');
    END IF;

    IF v_env NOT IN ('production', 'test') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid environment');
    END IF;

    SELECT c.company_type::text
    INTO v_prev
    FROM public.companies c
    WHERE c.id = p_company_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company not found');
    END IF;

    IF v_prev = v_env THEN
        RETURN jsonb_build_object('success', true, 'environment', v_env, 'changed', false);
    END IF;

    -- Update both company_type AND environment_type to keep them in sync
    UPDATE public.companies
    SET company_type = v_env::public.company_type,
        environment_type = v_env,
        updated_at = now()
    WHERE id = p_company_id;

    PERFORM public.log_company_event(
        'company_environment_changed',
        p_company_id,
        auth.uid(),
        jsonb_build_object(
            'from_environment', v_prev,
            'to_environment', v_env
        )
    );

    RETURN jsonb_build_object('success', true, 'environment', v_env, 'changed', true);
END;
$$;

COMMIT;
