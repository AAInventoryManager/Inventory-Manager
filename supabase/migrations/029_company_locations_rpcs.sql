-- Company locations RPCs (Shipping/Receiving)

BEGIN;

CREATE OR REPLACE FUNCTION public.log_location_audit_event(
    p_event_name TEXT,
    p_location_id UUID,
    p_company_id UUID,
    p_actor_user_id UUID,
    p_changed_fields TEXT[] DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.audit_log (
        action,
        table_name,
        record_id,
        company_id,
        user_id,
        new_values,
        changed_fields
    ) VALUES (
        'INSERT',
        'location_events',
        p_location_id,
        p_company_id,
        p_actor_user_id,
        COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
            'event_name', p_event_name,
            'location_id', p_location_id,
            'company_id', p_company_id,
            'actor_user_id', p_actor_user_id,
            'timestamp', now(),
            'changed_fields', p_changed_fields
        ),
        p_changed_fields
    );
END;
$$;

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
        jsonb_build_object(
            'name', v_name,
            'location_type', v_location_type,
            'is_default_ship_to', v_set_default_ship_to,
            'is_default_receive_at', v_set_default_receive_at
        )
    );

    IF v_set_default_ship_to THEN
        PERFORM public.log_location_audit_event(
            'location_default_changed',
            v_location_id,
            p_company_id,
            v_actor,
            ARRAY['is_default_ship_to'],
            jsonb_build_object(
                'default_kind', 'ship_to',
                'previous_location_id', v_prev_ship_to,
                'new_location_id', v_location_id
            )
        );
    END IF;

    IF v_set_default_receive_at THEN
        PERFORM public.log_location_audit_event(
            'location_default_changed',
            v_location_id,
            p_company_id,
            v_actor,
            ARRAY['is_default_receive_at'],
            jsonb_build_object(
                'default_kind', 'receive_at',
                'previous_location_id', v_prev_receive_at,
                'new_location_id', v_location_id
            )
        );
    END IF;

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

    IF NOT v_location.is_active THEN
        RETURN json_build_object('success', false, 'error', 'Location is archived');
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
    WHERE id = p_location_id
      AND is_active = true;

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

CREATE OR REPLACE FUNCTION public.set_default_location(
    p_location_id UUID,
    p_default_type TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_location public.company_locations%ROWTYPE;
    v_default_type TEXT;
    v_prev_default UUID;
    v_changed_fields TEXT[];
BEGIN
    IF p_location_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing location_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    v_default_type := lower(trim(p_default_type));
    IF v_default_type NOT IN ('ship_to','receive_at') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid default type');
    END IF;

    SELECT *
    INTO v_location
    FROM public.company_locations
    WHERE id = p_location_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Location not found');
    END IF;

    IF NOT v_location.is_active THEN
        RETURN json_build_object('success', false, 'error', 'Location is archived');
    END IF;

    IF NOT public.check_permission(v_location.company_id, 'orders:manage_shipping') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_default_type = 'ship_to' THEN
        IF v_location.is_default_ship_to THEN
            RETURN json_build_object('success', true, 'location_id', v_location.id, 'already_default', true);
        END IF;

        SELECT id
        INTO v_prev_default
        FROM public.company_locations
        WHERE company_id = v_location.company_id
          AND is_default_ship_to = true
          AND is_active = true
        LIMIT 1
        FOR UPDATE;

        UPDATE public.company_locations
        SET is_default_ship_to = false,
            updated_at = now()
        WHERE company_id = v_location.company_id
          AND is_default_ship_to = true
          AND is_active = true;

        UPDATE public.company_locations
        SET is_default_ship_to = true,
            updated_at = now()
        WHERE id = v_location.id;

        v_changed_fields := ARRAY['is_default_ship_to'];
    ELSE
        IF v_location.is_default_receive_at THEN
            RETURN json_build_object('success', true, 'location_id', v_location.id, 'already_default', true);
        END IF;

        SELECT id
        INTO v_prev_default
        FROM public.company_locations
        WHERE company_id = v_location.company_id
          AND is_default_receive_at = true
          AND is_active = true
        LIMIT 1
        FOR UPDATE;

        UPDATE public.company_locations
        SET is_default_receive_at = false,
            updated_at = now()
        WHERE company_id = v_location.company_id
          AND is_default_receive_at = true
          AND is_active = true;

        UPDATE public.company_locations
        SET is_default_receive_at = true,
            updated_at = now()
        WHERE id = v_location.id;

        v_changed_fields := ARRAY['is_default_receive_at'];
    END IF;

    PERFORM public.log_location_audit_event(
        'location_default_changed',
        v_location.id,
        v_location.company_id,
        v_actor,
        v_changed_fields,
        jsonb_build_object(
            'default_kind', v_default_type,
            'previous_location_id', v_prev_default,
            'new_location_id', v_location.id
        )
    );

    RETURN json_build_object('success', true, 'location_id', v_location.id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_default_location(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.archive_company_location(
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
    v_ref_exists BOOLEAN;
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

    IF NOT v_location.is_active THEN
        RETURN json_build_object('success', false, 'error', 'Location is already archived');
    END IF;

    IF NOT public.check_permission(v_location.company_id, 'orders:manage_shipping') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_location.is_default_ship_to OR v_location.is_default_receive_at THEN
        RETURN json_build_object('success', false, 'error', 'Cannot archive a default location');
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'purchase_orders'
          AND column_name = 'ship_to_location_id'
    ) THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.purchase_orders WHERE ship_to_location_id = $1)' INTO v_ref_exists USING v_location.id;
        IF v_ref_exists THEN
            RETURN json_build_object('success', false, 'error', 'Location is referenced by purchase orders');
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'receipts'
          AND column_name = 'receive_at_location_id'
    ) THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.receipts WHERE receive_at_location_id = $1)' INTO v_ref_exists USING v_location.id;
        IF v_ref_exists THEN
            RETURN json_build_object('success', false, 'error', 'Location is referenced by receipts');
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'jobs'
          AND column_name = 'job_site_location_id'
    ) THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.jobs WHERE job_site_location_id = $1)' INTO v_ref_exists USING v_location.id;
        IF v_ref_exists THEN
            RETURN json_build_object('success', false, 'error', 'Location is referenced by jobs');
        END IF;
    END IF;

    UPDATE public.company_locations
    SET is_active = false,
        updated_at = now()
    WHERE id = v_location.id
      AND is_active = true;

    PERFORM public.log_location_audit_event(
        'location_archived',
        v_location.id,
        v_location.company_id,
        v_actor,
        ARRAY['is_active'],
        jsonb_build_object('previous_is_active', true, 'new_is_active', false)
    );

    RETURN json_build_object('success', true, 'location_id', v_location.id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_company_location(UUID) TO authenticated;

COMMIT;
