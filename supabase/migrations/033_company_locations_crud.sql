-- Company locations CRUD improvements

BEGIN;

CREATE OR REPLACE FUNCTION public.update_company_location(
    p_location_id UUID,
    p_name TEXT,
    p_location_type TEXT,
    p_address_line1 TEXT,
    p_address_line2 TEXT,
    p_city TEXT,
    p_state_region TEXT,
    p_postal_code TEXT,
    p_country_code CHAR(2)
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_location public.company_locations%ROWTYPE;
    v_location_type TEXT;
    v_country_code TEXT;
    v_name TEXT;
    v_address_line1 TEXT;
    v_address_line2 TEXT;
    v_city TEXT;
    v_state_region TEXT;
    v_postal_code TEXT;
    v_changed_fields TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF p_location_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing location_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT *
    INTO v_location
    FROM public.company_locations
    WHERE id = p_location_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Location not found');
    END IF;

    IF NOT public.check_permission(v_location.company_id, 'orders:manage_shipping') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    v_name := nullif(trim(p_name), '');
    v_address_line1 := nullif(trim(p_address_line1), '');
    v_address_line2 := nullif(trim(p_address_line2), '');
    v_city := nullif(trim(p_city), '');
    v_state_region := nullif(trim(p_state_region), '');
    v_postal_code := nullif(trim(p_postal_code), '');
    v_location_type := lower(trim(p_location_type));
    v_country_code := upper(trim(p_country_code));

    IF v_name IS NULL OR v_address_line1 IS NULL OR v_city IS NULL OR v_state_region IS NULL OR v_postal_code IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_location_type IS NULL OR v_location_type NOT IN ('warehouse','yard','office','job_site','other') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid location type');
    END IF;

    IF v_country_code IS NULL OR v_country_code !~ '^[A-Z]{2}$' THEN
        RETURN json_build_object('success', false, 'error', 'Invalid country code');
    END IF;

    IF v_location.name IS DISTINCT FROM v_name THEN
        v_changed_fields := array_append(v_changed_fields, 'name');
    END IF;
    IF v_location.location_type IS DISTINCT FROM v_location_type THEN
        v_changed_fields := array_append(v_changed_fields, 'location_type');
    END IF;
    IF v_location.address_line1 IS DISTINCT FROM v_address_line1 THEN
        v_changed_fields := array_append(v_changed_fields, 'address_line1');
    END IF;
    IF v_location.address_line2 IS DISTINCT FROM v_address_line2 THEN
        v_changed_fields := array_append(v_changed_fields, 'address_line2');
    END IF;
    IF v_location.city IS DISTINCT FROM v_city THEN
        v_changed_fields := array_append(v_changed_fields, 'city');
    END IF;
    IF v_location.state_region IS DISTINCT FROM v_state_region THEN
        v_changed_fields := array_append(v_changed_fields, 'state_region');
    END IF;
    IF v_location.postal_code IS DISTINCT FROM v_postal_code THEN
        v_changed_fields := array_append(v_changed_fields, 'postal_code');
    END IF;
    IF v_location.country_code IS DISTINCT FROM v_country_code THEN
        v_changed_fields := array_append(v_changed_fields, 'country_code');
    END IF;

    UPDATE public.company_locations
    SET name = v_name,
        location_type = v_location_type,
        address_line1 = v_address_line1,
        address_line2 = v_address_line2,
        city = v_city,
        state_region = v_state_region,
        postal_code = v_postal_code,
        country_code = v_country_code,
        updated_at = now()
    WHERE id = p_location_id;

    PERFORM public.log_location_audit_event(
        'location_updated',
        v_location.id,
        v_location.company_id,
        v_actor,
        v_changed_fields,
        jsonb_build_object('location_id', v_location.id)
    );

    RETURN json_build_object('success', true, 'location_id', v_location.id, 'changed_fields', v_changed_fields);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_company_location(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, CHAR(2)) TO authenticated;

CREATE OR REPLACE FUNCTION public.restore_company_location(
    p_location_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_location public.company_locations%ROWTYPE;
    v_changed_fields TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF p_location_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing location_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT *
    INTO v_location
    FROM public.company_locations
    WHERE id = p_location_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Location not found');
    END IF;

    IF NOT public.check_permission(v_location.company_id, 'orders:manage_shipping') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_location.is_active THEN
        RETURN json_build_object('success', true, 'location_id', v_location.id, 'already_active', true);
    END IF;

    v_changed_fields := array_append(v_changed_fields, 'is_active');
    IF v_location.is_default_ship_to THEN
        v_changed_fields := array_append(v_changed_fields, 'is_default_ship_to');
    END IF;
    IF v_location.is_default_receive_at THEN
        v_changed_fields := array_append(v_changed_fields, 'is_default_receive_at');
    END IF;

    UPDATE public.company_locations
    SET is_active = true,
        is_default_ship_to = false,
        is_default_receive_at = false,
        updated_at = now()
    WHERE id = v_location.id;

    PERFORM public.log_location_audit_event(
        'location_restored',
        v_location.id,
        v_location.company_id,
        v_actor,
        v_changed_fields,
        jsonb_build_object(
            'previous_is_active', false,
            'new_is_active', true,
            'previous_is_default_ship_to', v_location.is_default_ship_to,
            'previous_is_default_receive_at', v_location.is_default_receive_at
        )
    );

    RETURN json_build_object('success', true, 'location_id', v_location.id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.restore_company_location(UUID) TO authenticated;

COMMIT;
