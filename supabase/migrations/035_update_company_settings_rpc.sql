-- Update company settings for onboarding/profile updates.

BEGIN;

CREATE OR REPLACE FUNCTION public.update_company_settings(
    p_company_id UUID,
    p_settings_patch JSONB DEFAULT '{}'::jsonb,
    p_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_role TEXT;
    v_settings JSONB;
    v_name TEXT;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    v_role := public.get_user_role(p_company_id);
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT name, settings
    INTO v_name, v_settings
    FROM public.companies
    WHERE id = p_company_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company not found';
    END IF;

    v_settings := COALESCE(v_settings, '{}'::jsonb) || COALESCE(p_settings_patch, '{}'::jsonb);

    IF p_name IS NOT NULL AND length(trim(p_name)) > 0 THEN
        v_name := trim(p_name);
    END IF;

    UPDATE public.companies
    SET name = v_name,
        settings = v_settings,
        updated_at = now()
    WHERE id = p_company_id;

    RETURN jsonb_build_object('name', v_name, 'settings', v_settings);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_company_settings(UUID, JSONB, TEXT) TO authenticated;

COMMIT;
