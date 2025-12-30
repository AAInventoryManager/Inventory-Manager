-- Company onboarding RPCs

BEGIN;

CREATE OR REPLACE FUNCTION public.get_onboarding_state(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_state TEXT;
    v_role TEXT;
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

    SELECT onboarding_state
    INTO v_state
    FROM public.companies
    WHERE id = p_company_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company not found';
    END IF;

    RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION public.advance_onboarding_state(
    p_company_id UUID,
    p_target_state TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_role TEXT;
    v_is_super BOOLEAN := false;
    v_target TEXT := upper(trim(COALESCE(p_target_state, '')));
    v_current TEXT;
    v_company_name TEXT;
    v_settings JSONB;
    v_states TEXT[] := ARRAY[
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ];
    v_current_rank INTEGER;
    v_target_rank INTEGER;
    v_missing TEXT[];
    v_required_fields TEXT[] := ARRAY[
        'primary_contact_email',
        'timezone'
    ];
    v_field TEXT;
    v_locations_ok BOOLEAN := false;
    v_invites_ok BOOLEAN := false;
    v_skip_invites BOOLEAN := false;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    v_role := public.get_user_role(p_company_id);
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    v_is_super := v_role = 'super_user';

    IF v_target = '' THEN
        RAISE EXCEPTION 'Missing target state';
    END IF;

    IF v_target NOT IN (
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ) THEN
        RAISE EXCEPTION 'Invalid target state';
    END IF;

    SELECT onboarding_state, name, settings
    INTO v_current, v_company_name, v_settings
    FROM public.companies
    WHERE id = p_company_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company not found';
    END IF;

    v_current := upper(trim(COALESCE(v_current, 'UNINITIALIZED')));
    IF v_current NOT IN (
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ) THEN
        RAISE EXCEPTION 'Invalid current state';
    END IF;

    IF v_target = v_current THEN
        RETURN v_current;
    END IF;

    v_current_rank := array_position(v_states, v_current);
    v_target_rank := array_position(v_states, v_target);

    IF v_current_rank IS NULL OR v_target_rank IS NULL THEN
        RAISE EXCEPTION 'Invalid onboarding state';
    END IF;

    IF v_target_rank < v_current_rank THEN
        RAISE EXCEPTION 'Invalid transition';
    END IF;

    IF NOT v_is_super AND v_target_rank <> v_current_rank + 1 THEN
        RAISE EXCEPTION 'Invalid transition';
    END IF;

    v_settings := COALESCE(v_settings, '{}'::jsonb);

    IF v_target_rank >= array_position(v_states, 'COMPANY_PROFILE_COMPLETE') THEN
        v_missing := ARRAY[]::TEXT[];
        IF nullif(trim(v_company_name), '') IS NULL THEN
            v_missing := array_append(v_missing, 'name');
        END IF;

        FOREACH v_field IN ARRAY v_required_fields LOOP
            IF nullif(trim(v_settings->>v_field), '') IS NULL THEN
                v_missing := array_append(v_missing, v_field);
            END IF;
        END LOOP;

        IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
            RAISE EXCEPTION 'Company profile incomplete: %', array_to_string(v_missing, ', ');
        END IF;
    END IF;

    IF v_target_rank >= array_position(v_states, 'LOCATIONS_CONFIGURED') THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.company_locations
            WHERE company_id = p_company_id
              AND is_active = true
        ) INTO v_locations_ok;

        IF NOT v_locations_ok THEN
            RAISE EXCEPTION 'Company locations required';
        END IF;
    END IF;

    IF v_target_rank >= array_position(v_states, 'USERS_INVITED') THEN
        SELECT EXISTS (
            SELECT 1
            FROM public.invitations
            WHERE company_id = p_company_id
        ) INTO v_invites_ok;

        v_skip_invites := COALESCE(lower(trim(v_settings->>'onboarding_skip_invites')), '') IN ('true','t','1','yes','y');

        IF NOT (v_invites_ok OR v_skip_invites) THEN
            RAISE EXCEPTION 'User invitations required';
        END IF;
    END IF;

    UPDATE public.companies
    SET onboarding_state = v_target
    WHERE id = p_company_id;

    INSERT INTO public.audit_log (
        action,
        table_name,
        record_id,
        company_id,
        user_id,
        new_values
    ) VALUES (
        'INSERT',
        'onboarding_events',
        p_company_id,
        p_company_id,
        v_actor,
        jsonb_build_object(
            'event_name', 'onboarding_state_changed',
            'company_id', p_company_id,
            'from_state', v_current,
            'to_state', v_target,
            'actor_user_id', v_actor,
            'timestamp', now()
        )
    );

    RETURN v_target;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_advance_onboarding(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_role TEXT;
    v_current TEXT;
    v_company_name TEXT;
    v_settings JSONB;
    v_states TEXT[] := ARRAY[
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ];
    v_current_rank INTEGER;
    v_next_rank INTEGER;
    v_next TEXT;
    v_missing TEXT[];
    v_required_fields TEXT[] := ARRAY[
        'primary_contact_email',
        'timezone'
    ];
    v_field TEXT;
    v_profile_ok BOOLEAN := false;
    v_locations_ok BOOLEAN := false;
    v_invites_ok BOOLEAN := false;
    v_skip_invites BOOLEAN := false;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    v_role := public.get_user_role(p_company_id);
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT onboarding_state, name, settings
    INTO v_current, v_company_name, v_settings
    FROM public.companies
    WHERE id = p_company_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Company not found';
    END IF;

    v_current := upper(trim(COALESCE(v_current, 'UNINITIALIZED')));
    IF v_current NOT IN (
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ) THEN
        RAISE EXCEPTION 'Invalid current state';
    END IF;

    v_settings := COALESCE(v_settings, '{}'::jsonb);

    v_missing := ARRAY[]::TEXT[];
    IF nullif(trim(v_company_name), '') IS NULL THEN
        v_missing := array_append(v_missing, 'name');
    END IF;

    FOREACH v_field IN ARRAY v_required_fields LOOP
        IF nullif(trim(v_settings->>v_field), '') IS NULL THEN
            v_missing := array_append(v_missing, v_field);
        END IF;
    END LOOP;

    v_profile_ok := COALESCE(array_length(v_missing, 1), 0) = 0;

    SELECT EXISTS (
        SELECT 1
        FROM public.company_locations
        WHERE company_id = p_company_id
          AND is_active = true
    ) INTO v_locations_ok;

    SELECT EXISTS (
        SELECT 1
        FROM public.invitations
        WHERE company_id = p_company_id
    ) INTO v_invites_ok;

    v_skip_invites := COALESCE(lower(trim(v_settings->>'onboarding_skip_invites')), '') IN ('true','t','1','yes','y');
    v_invites_ok := v_invites_ok OR v_skip_invites;

    v_current_rank := array_position(v_states, v_current);
    IF v_current_rank IS NULL THEN
        RAISE EXCEPTION 'Invalid current state';
    END IF;

    LOOP
        v_next_rank := v_current_rank + 1;
        EXIT WHEN v_next_rank > array_length(v_states, 1);

        v_next := v_states[v_next_rank];

        IF v_next = 'COMPANY_PROFILE_COMPLETE' AND NOT v_profile_ok THEN
            EXIT;
        END IF;

        IF v_next = 'LOCATIONS_CONFIGURED' AND NOT (v_profile_ok AND v_locations_ok) THEN
            EXIT;
        END IF;

        IF v_next = 'USERS_INVITED' AND NOT (v_profile_ok AND v_locations_ok AND v_invites_ok) THEN
            EXIT;
        END IF;

        IF v_next = 'ONBOARDING_COMPLETE' AND NOT (v_profile_ok AND v_locations_ok AND v_invites_ok) THEN
            EXIT;
        END IF;

        UPDATE public.companies
        SET onboarding_state = v_next
        WHERE id = p_company_id;

        INSERT INTO public.audit_log (
            action,
            table_name,
            record_id,
            company_id,
            user_id,
            new_values
        ) VALUES (
            'INSERT',
            'onboarding_events',
            p_company_id,
            p_company_id,
            v_actor,
            jsonb_build_object(
                'event_name', 'onboarding_state_changed',
                'company_id', p_company_id,
                'from_state', v_current,
                'to_state', v_next,
                'actor_user_id', v_actor,
                'timestamp', now()
            )
        );

        v_current := v_next;
        v_current_rank := v_next_rank;
    END LOOP;

    RETURN v_current;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_onboarding_state(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.advance_onboarding_state(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_advance_onboarding(UUID) TO authenticated;

COMMIT;
