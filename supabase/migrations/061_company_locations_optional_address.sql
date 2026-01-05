-- Allow optional address fields for company locations

BEGIN;

ALTER TABLE public.company_locations
  ALTER COLUMN address_line1 DROP NOT NULL,
  ALTER COLUMN city DROP NOT NULL,
  ALTER COLUMN state_region DROP NOT NULL,
  ALTER COLUMN postal_code DROP NOT NULL,
  ALTER COLUMN country_code DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.create_company_location(
    p_company_id UUID,
    p_name TEXT,
    p_location_type TEXT,
    p_address_line1 TEXT,
    p_address_line2 TEXT,
    p_city TEXT,
    p_state_region TEXT,
    p_postal_code TEXT,
    p_country_code CHAR(2),
    p_set_default_ship_to BOOLEAN DEFAULT false,
    p_set_default_receive_at BOOLEAN DEFAULT false
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_location_id UUID;
    v_location_type TEXT;
    v_country_code TEXT;
    v_name TEXT;
    v_address_line1 TEXT;
    v_address_line2 TEXT;
    v_city TEXT;
    v_state_region TEXT;
    v_postal_code TEXT;
    v_set_default_ship_to BOOLEAN := COALESCE(p_set_default_ship_to, false);
    v_set_default_receive_at BOOLEAN := COALESCE(p_set_default_receive_at, false);
    v_prev_ship_to UUID;
    v_prev_receive_at UUID;
    v_changed_fields TEXT[] := ARRAY[
        'name',
        'location_type',
        'address_line1',
        'address_line2',
        'city',
        'state_region',
        'postal_code',
        'country_code',
        'is_active',
        'is_default_ship_to',
        'is_default_receive_at'
    ];
BEGIN
    IF p_company_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    IF NOT public.check_permission(p_company_id, 'orders:manage_shipping') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    v_name := nullif(trim(p_name), '');
    v_address_line1 := nullif(trim(p_address_line1), '');
    v_address_line2 := nullif(trim(p_address_line2), '');
    v_city := nullif(trim(p_city), '');
    v_state_region := nullif(trim(p_state_region), '');
    v_postal_code := nullif(trim(p_postal_code), '');
    v_location_type := lower(trim(p_location_type));
    v_country_code := nullif(upper(trim(p_country_code)), '');

    IF v_name IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_location_type IS NULL OR v_location_type NOT IN ('warehouse','yard','office','job_site','other') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid location type');
    END IF;

    IF v_country_code IS NOT NULL AND v_country_code !~ '^[A-Z]{2}$' THEN
        RETURN json_build_object('success', false, 'error', 'Invalid country code');
    END IF;

    IF NOT v_set_default_ship_to THEN
        SELECT id
        INTO v_prev_ship_to
        FROM public.company_locations
        WHERE company_id = p_company_id
          AND is_default_ship_to = true
          AND is_active = true
        LIMIT 1;
        IF v_prev_ship_to IS NULL THEN
            v_set_default_ship_to := true;
        END IF;
    ELSE
        SELECT id
        INTO v_prev_ship_to
        FROM public.company_locations
        WHERE company_id = p_company_id
          AND is_default_ship_to = true
          AND is_active = true
        LIMIT 1
        FOR UPDATE;
    END IF;

    IF NOT v_set_default_receive_at THEN
        SELECT id
        INTO v_prev_receive_at
        FROM public.company_locations
        WHERE company_id = p_company_id
          AND is_default_receive_at = true
          AND is_active = true
        LIMIT 1;
        IF v_prev_receive_at IS NULL THEN
            v_set_default_receive_at := true;
        END IF;
    ELSE
        SELECT id
        INTO v_prev_receive_at
        FROM public.company_locations
        WHERE company_id = p_company_id
          AND is_default_receive_at = true
          AND is_active = true
        LIMIT 1
        FOR UPDATE;
    END IF;

    IF v_set_default_ship_to THEN
        UPDATE public.company_locations
        SET is_default_ship_to = false,
            updated_at = now()
        WHERE company_id = p_company_id
          AND is_default_ship_to = true
          AND is_active = true;
    END IF;

    IF v_set_default_receive_at THEN
        UPDATE public.company_locations
        SET is_default_receive_at = false,
            updated_at = now()
        WHERE company_id = p_company_id
          AND is_default_receive_at = true
          AND is_active = true;
    END IF;

    INSERT INTO public.company_locations (
        company_id,
        name,
        location_type,
        address_line1,
        address_line2,
        city,
        state_region,
        postal_code,
        country_code,
        is_active,
        is_default_ship_to,
        is_default_receive_at
    ) VALUES (
        p_company_id,
        v_name,
        v_location_type,
        v_address_line1,
        v_address_line2,
        v_city,
        v_state_region,
        v_postal_code,
        v_country_code,
        true,
        v_set_default_ship_to,
        v_set_default_receive_at
    )
    RETURNING id INTO v_location_id;

    PERFORM public.log_location_audit_event(
        'location_created',
        v_location_id,
        p_company_id,
        v_actor,
        v_changed_fields,
        jsonb_build_object('location_id', v_location_id)
    );

    RETURN json_build_object('success', true, 'location_id', v_location_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_company_location(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, CHAR(2), BOOLEAN, BOOLEAN) TO authenticated;

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
    v_country_code := nullif(upper(trim(p_country_code)), '');

    IF v_name IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_location_type IS NULL OR v_location_type NOT IN ('warehouse','yard','office','job_site','other') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid location type');
    END IF;

    IF v_country_code IS NOT NULL AND v_country_code !~ '^[A-Z]{2}$' THEN
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

COMMIT;
