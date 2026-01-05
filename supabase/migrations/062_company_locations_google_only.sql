-- Migrate company_locations to Google Places canonical address fields

BEGIN;

ALTER TABLE public.company_locations
  ADD COLUMN IF NOT EXISTS google_place_id TEXT,
  ADD COLUMN IF NOT EXISTS google_formatted_address TEXT,
  ADD COLUMN IF NOT EXISTS google_address_components JSONB;

UPDATE public.company_locations
SET google_formatted_address = NULLIF(TRIM(
  CONCAT_WS(E'\n',
    NULLIF(TRIM(address_line1), ''),
    NULLIF(TRIM(address_line2), ''),
    NULLIF(TRIM(
      CONCAT_WS(' ',
        NULLIF(TRIM(CONCAT_WS(', ', NULLIF(TRIM(city), ''), NULLIF(TRIM(state_region), ''))), ''),
        NULLIF(TRIM(postal_code), '')
      )
    ), ''),
    NULLIF(TRIM(country_code), '')
  )
), '')
WHERE (google_formatted_address IS NULL OR TRIM(google_formatted_address) = '');

UPDATE public.company_locations
SET google_formatted_address = ''
WHERE google_formatted_address IS NULL;

ALTER TABLE public.company_locations
  ALTER COLUMN google_formatted_address SET NOT NULL;

ALTER TABLE public.company_locations
  DROP COLUMN IF EXISTS address_line1,
  DROP COLUMN IF EXISTS address_line2,
  DROP COLUMN IF EXISTS city,
  DROP COLUMN IF EXISTS state_region,
  DROP COLUMN IF EXISTS postal_code,
  DROP COLUMN IF EXISTS country_code;

DROP FUNCTION IF EXISTS public.create_company_location(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, CHAR(2), BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS public.update_company_location(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, CHAR(2));

CREATE OR REPLACE FUNCTION public.create_company_location(
    p_company_id UUID,
    p_name TEXT,
    p_location_type TEXT,
    p_google_formatted_address TEXT,
    p_google_place_id TEXT,
    p_google_address_components JSONB,
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
    v_name TEXT;
    v_google_formatted_address TEXT;
    v_google_place_id TEXT;
    v_google_address_components JSONB;
    v_set_default_ship_to BOOLEAN := COALESCE(p_set_default_ship_to, false);
    v_set_default_receive_at BOOLEAN := COALESCE(p_set_default_receive_at, false);
    v_prev_ship_to UUID;
    v_prev_receive_at UUID;
    v_changed_fields TEXT[] := ARRAY[
        'name',
        'location_type',
        'google_formatted_address',
        'google_place_id',
        'google_address_components',
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
    v_location_type := lower(trim(p_location_type));
    v_google_formatted_address := nullif(trim(p_google_formatted_address), '');
    v_google_place_id := nullif(trim(p_google_place_id), '');
    v_google_address_components := p_google_address_components;

    IF v_name IS NULL OR v_google_formatted_address IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_location_type IS NULL OR v_location_type NOT IN ('warehouse','yard','office','job_site','other') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid location type');
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
        google_formatted_address,
        google_place_id,
        google_address_components,
        is_active,
        is_default_ship_to,
        is_default_receive_at
    ) VALUES (
        p_company_id,
        v_name,
        v_location_type,
        v_google_formatted_address,
        v_google_place_id,
        v_google_address_components,
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

GRANT EXECUTE ON FUNCTION public.create_company_location(UUID, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_company_location(
    p_location_id UUID,
    p_name TEXT,
    p_location_type TEXT,
    p_google_formatted_address TEXT,
    p_google_place_id TEXT,
    p_google_address_components JSONB
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
    v_name TEXT;
    v_google_formatted_address TEXT;
    v_google_place_id TEXT;
    v_google_address_components JSONB;
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
    v_location_type := lower(trim(p_location_type));
    v_google_formatted_address := nullif(trim(p_google_formatted_address), '');
    v_google_place_id := nullif(trim(p_google_place_id), '');
    v_google_address_components := p_google_address_components;

    IF v_name IS NULL OR v_google_formatted_address IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_location_type IS NULL OR v_location_type NOT IN ('warehouse','yard','office','job_site','other') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid location type');
    END IF;

    IF v_location.name IS DISTINCT FROM v_name THEN
        v_changed_fields := array_append(v_changed_fields, 'name');
    END IF;
    IF v_location.location_type IS DISTINCT FROM v_location_type THEN
        v_changed_fields := array_append(v_changed_fields, 'location_type');
    END IF;
    IF v_location.google_formatted_address IS DISTINCT FROM v_google_formatted_address THEN
        v_changed_fields := array_append(v_changed_fields, 'google_formatted_address');
    END IF;
    IF v_location.google_place_id IS DISTINCT FROM v_google_place_id THEN
        v_changed_fields := array_append(v_changed_fields, 'google_place_id');
    END IF;
    IF v_location.google_address_components IS DISTINCT FROM v_google_address_components THEN
        v_changed_fields := array_append(v_changed_fields, 'google_address_components');
    END IF;

    UPDATE public.company_locations
    SET name = v_name,
        location_type = v_location_type,
        google_formatted_address = v_google_formatted_address,
        google_place_id = v_google_place_id,
        google_address_components = v_google_address_components,
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

GRANT EXECUTE ON FUNCTION public.update_company_location(UUID, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;

COMMIT;
