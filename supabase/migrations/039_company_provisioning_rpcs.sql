-- Company provisioning RPC (super_user only) + invite acceptance update

BEGIN;

CREATE OR REPLACE FUNCTION public.log_company_event(
    p_event_name TEXT,
    p_company_id UUID,
    p_actor_user_id UUID,
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
        new_values
    ) VALUES (
        'INSERT',
        'company_events',
        p_company_id,
        p_company_id,
        p_actor_user_id,
        COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
            'event_name', p_event_name,
            'company_id', p_company_id,
            'actor_user_id', p_actor_user_id,
            'timestamp', now()
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.provision_company(
    p_name TEXT,
    p_slug TEXT DEFAULT NULL,
    p_subscription_tier TEXT DEFAULT NULL,
    p_subscription_tier_reason TEXT DEFAULT NULL,
    p_subscription_tier_ends_at TIMESTAMPTZ DEFAULT NULL,
    p_seed_inventory BOOLEAN DEFAULT false,
    p_source_company_id UUID DEFAULT NULL,
    p_seed_dedupe_key TEXT DEFAULT 'sku',
    p_user_assignments JSONB DEFAULT '[]'::jsonb,
    p_include_actor_as_admin BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_name TEXT := nullif(trim(p_name), '');
    v_slug TEXT;
    v_slug_base TEXT;
    v_slug_suffix INTEGER := 0;
    v_company_id UUID;
    v_subscription TEXT := lower(trim(COALESCE(p_subscription_tier, '')));
    v_reason TEXT := nullif(trim(COALESCE(p_subscription_tier_reason, 'Provisioning')), '');
    v_seed JSONB := NULL;
    v_override JSONB := NULL;
    v_assignments JSONB := COALESCE(p_user_assignments, '[]'::jsonb);
    v_members_added INTEGER := 0;
    v_member_ids UUID[] := ARRAY[]::uuid[];
    v_member_roles TEXT[] := ARRAY[]::text[];
    v_duplicate_users UUID[];
    v_missing_users UUID[];
    v_invalid_roles TEXT[];
    v_new_member_ids UUID[];
    v_new_member_roles TEXT[];
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF v_name IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company name required');
    END IF;

    v_slug := lower(trim(COALESCE(p_slug, '')));
    IF v_slug = '' THEN
        v_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
        v_slug := regexp_replace(v_slug, '^-|-$', '', 'g');
    END IF;

    IF v_slug = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Slug required');
    END IF;

    IF v_slug !~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$' OR length(v_slug) < 2 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid slug format');
    END IF;

    v_slug_base := v_slug;
    WHILE EXISTS (SELECT 1 FROM public.companies WHERE slug = v_slug) LOOP
        v_slug_suffix := v_slug_suffix + 1;
        v_slug := v_slug_base || '-' || v_slug_suffix::text;
    END LOOP;

    IF v_subscription = '' AND p_subscription_tier_ends_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Subscription tier required when setting an end date');
    END IF;

    IF p_seed_inventory AND p_source_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source company required for seeding');
    END IF;

    IF v_assignments IS NULL OR jsonb_typeof(v_assignments) IS NULL THEN
        v_assignments := '[]'::jsonb;
    END IF;

    IF jsonb_typeof(v_assignments) <> 'array' THEN
        RETURN jsonb_build_object('success', false, 'error', 'user_assignments must be an array');
    END IF;

    WITH assignments AS (
        SELECT
            nullif(trim(value->>'user_id'), '')::uuid AS user_id,
            lower(trim(COALESCE(value->>'role', 'member'))) AS role
        FROM jsonb_array_elements(v_assignments)
        WHERE NOT (p_include_actor_as_admin AND nullif(trim(value->>'user_id'), '')::uuid = v_actor)
    ),
    dupes AS (
        SELECT user_id
        FROM assignments
        GROUP BY user_id
        HAVING COUNT(*) > 1
    ),
    missing AS (
        SELECT a.user_id
        FROM assignments a
        LEFT JOIN auth.users u ON u.id = a.user_id
        WHERE a.user_id IS NOT NULL AND u.id IS NULL
    ),
    invalid AS (
        SELECT role
        FROM assignments
        WHERE user_id IS NULL OR role NOT IN ('admin','member','viewer')
    )
    SELECT
        (SELECT array_agg(user_id) FROM dupes),
        (SELECT array_agg(user_id) FROM missing),
        (SELECT array_agg(role) FROM invalid)
    INTO v_duplicate_users, v_missing_users, v_invalid_roles;

    IF v_invalid_roles IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid user assignments');
    END IF;

    IF v_duplicate_users IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Duplicate user assignments');
    END IF;

    IF v_missing_users IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unknown user_id in assignments');
    END IF;

    INSERT INTO public.companies (name, slug, onboarding_state)
    VALUES (v_name, v_slug, 'UNINITIALIZED')
    RETURNING id INTO v_company_id;

    IF p_include_actor_as_admin THEN
        INSERT INTO public.company_members (
            company_id,
            user_id,
            role,
            invited_by,
            assigned_admin_id,
            is_super_user
        ) VALUES (
            v_company_id,
            v_actor,
            'admin',
            v_actor,
            v_actor,
            false
        ) ON CONFLICT (company_id, user_id) DO NOTHING;
        GET DIAGNOSTICS v_members_added = ROW_COUNT;
        IF v_members_added > 0 THEN
            v_member_ids := array_append(v_member_ids, v_actor);
            v_member_roles := array_append(v_member_roles, 'admin');
        END IF;
    END IF;

    WITH assignments AS (
        SELECT
            nullif(trim(value->>'user_id'), '')::uuid AS user_id,
            lower(trim(COALESCE(value->>'role', 'member'))) AS role
        FROM jsonb_array_elements(v_assignments)
        WHERE NOT (p_include_actor_as_admin AND nullif(trim(value->>'user_id'), '')::uuid = v_actor)
    ),
    ins AS (
        INSERT INTO public.company_members (
            company_id,
            user_id,
            role,
            invited_by,
            assigned_admin_id,
            is_super_user
        )
        SELECT
            v_company_id,
            a.user_id,
            a.role,
            v_actor,
            v_actor,
            false
        FROM assignments a
        ON CONFLICT (company_id, user_id) DO NOTHING
        RETURNING user_id, role
    )
    SELECT
        COALESCE(array_agg(user_id), ARRAY[]::uuid[]),
        COALESCE(array_agg(role), ARRAY[]::text[])
    INTO v_new_member_ids, v_new_member_roles
    FROM ins;

    IF v_new_member_ids IS NOT NULL AND array_length(v_new_member_ids, 1) > 0 THEN
        v_member_ids := v_member_ids || v_new_member_ids;
        v_member_roles := v_member_roles || v_new_member_roles;
    END IF;

    v_members_added := COALESCE(array_length(v_member_ids, 1), 0);

    PERFORM public.log_company_event(
        'company_provisioned',
        v_company_id,
        v_actor,
        jsonb_build_object(
            'company_name', v_name,
            'company_slug', v_slug,
            'subscription_tier', nullif(v_subscription, ''),
            'subscription_tier_reason', v_reason,
            'subscription_tier_ends_at', p_subscription_tier_ends_at,
            'seed_inventory', p_seed_inventory,
            'source_company_id', p_source_company_id,
            'seed_dedupe_key', p_seed_dedupe_key,
            'include_actor_as_admin', p_include_actor_as_admin,
            'users_added_count', v_members_added
        )
    );

    IF v_members_added > 0 THEN
        PERFORM public.log_company_event(
            'company_members_added',
            v_company_id,
            v_actor,
            jsonb_build_object(
                'user_ids', v_member_ids,
                'roles', v_member_roles,
                'users_added_count', v_members_added
            )
        );
    END IF;

    IF v_subscription <> '' THEN
        BEGIN
            v_override := public.grant_company_tier_override(
                v_company_id,
                v_subscription,
                p_subscription_tier_ends_at
            );
            v_override := COALESCE(v_override, '{}'::jsonb) || jsonb_build_object(
                'tier', v_subscription,
                'reason', v_reason,
                'ends_at', p_subscription_tier_ends_at
            );
        EXCEPTION
            WHEN others THEN
                v_override := jsonb_build_object(
                    'success', false,
                    'tier', v_subscription,
                    'reason', v_reason,
                    'ends_at', p_subscription_tier_ends_at,
                    'error', SQLERRM
                );
        END;
    ELSE
        v_override := jsonb_build_object('success', false, 'skipped', true);
    END IF;

    IF p_seed_inventory THEN
        BEGIN
            v_seed := public.seed_company_inventory(
                p_source_company_id,
                v_company_id,
                'items_only',
                p_seed_dedupe_key
            );
        EXCEPTION
            WHEN others THEN
                v_seed := jsonb_build_object(
                    'success', false,
                    'error', SQLERRM
                );
        END;
    ELSE
        v_seed := jsonb_build_object('success', false, 'skipped', true);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'company_id', v_company_id,
        'company_name', v_name,
        'company_slug', v_slug,
        'users_added_count', v_members_added,
        'tier_override', v_override,
        'inventory_seed', v_seed
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.provision_company(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, BOOLEAN, UUID, TEXT, JSONB, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_company_invite(p_invite_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_invite RECORD;
    v_user_id UUID;
    v_existing_company UUID;
    v_admin_id UUID;
    v_latency_seconds INTEGER;
    v_now TIMESTAMPTZ := now();
    v_invite_email TEXT;
    v_auth_email TEXT;
    v_instance_id UUID;
BEGIN
    IF p_invite_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite id is required');
    END IF;

    SELECT id, company_id, email, role, invited_by_user_id, sent_at, expires_at, status
    INTO v_invite
    FROM public.company_invites
    WHERE id = p_invite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite not found');
    END IF;

    v_invite_email := lower(trim(v_invite.email));

    IF v_invite.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite is not pending');
    END IF;

    IF v_invite.expires_at <= v_now THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite has expired');
    END IF;

    IF auth.uid() IS NOT NULL THEN
        v_user_id := auth.uid();
        SELECT lower(trim(email))
        INTO v_auth_email
        FROM auth.users
        WHERE id = v_user_id;

        IF v_auth_email IS NULL OR v_auth_email <> v_invite_email THEN
            RETURN jsonb_build_object('success', false, 'error', 'Invitation was sent to a different email');
        END IF;
    ELSE
        SELECT id
        INTO v_user_id
        FROM auth.users
        WHERE lower(trim(email)) = v_invite_email
        LIMIT 1;
    END IF;

    IF v_user_id IS NULL THEN
        SELECT id INTO v_instance_id FROM auth.instances LIMIT 1;

        BEGIN
            INSERT INTO auth.users (
                instance_id,
                aud,
                role,
                email,
                encrypted_password,
                email_confirmed_at,
                raw_app_meta_data,
                raw_user_meta_data,
                created_at,
                updated_at
            ) VALUES (
                v_instance_id,
                'authenticated',
                'authenticated',
                v_invite_email,
                crypt(gen_random_uuid()::text, gen_salt('bf')),
                v_now,
                jsonb_build_object('provider', 'email', 'providers', ARRAY['email']),
                '{}'::jsonb,
                v_now,
                v_now
            )
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_user_id;
        EXCEPTION
            WHEN undefined_column THEN
                INSERT INTO auth.users (email)
                VALUES (v_invite_email)
                ON CONFLICT DO NOTHING
                RETURNING id INTO v_user_id;
        END;

        IF v_user_id IS NULL THEN
            SELECT id
            INTO v_user_id
            FROM auth.users
            WHERE lower(trim(email)) = v_invite_email
            LIMIT 1;
        END IF;

        IF v_user_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Failed to create user');
        END IF;

        BEGIN
            INSERT INTO auth.identities (
                id,
                user_id,
                identity_data,
                provider,
                provider_id,
                last_sign_in_at,
                created_at,
                updated_at
            ) VALUES (
                gen_random_uuid(),
                v_user_id,
                jsonb_build_object('sub', v_user_id::text, 'email', v_invite_email),
                'email',
                v_invite_email,
                v_now,
                v_now,
                v_now
            )
            ON CONFLICT DO NOTHING;
        EXCEPTION
            WHEN undefined_column THEN
                INSERT INTO auth.identities (
                    id,
                    user_id,
                    identity_data,
                    provider,
                    last_sign_in_at,
                    created_at,
                    updated_at
                ) VALUES (
                    gen_random_uuid(),
                    v_user_id,
                    jsonb_build_object('sub', v_user_id::text, 'email', v_invite_email),
                    'email',
                    v_now,
                    v_now,
                    v_now
                )
                ON CONFLICT DO NOTHING;
        END;
    END IF;

    SELECT company_id
    INTO v_existing_company
    FROM public.company_members
    WHERE user_id = v_user_id
      AND company_id = v_invite.company_id;

    IF v_existing_company IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User is already a member of this company');
    END IF;

    SELECT user_id
    INTO v_admin_id
    FROM public.company_members
    WHERE company_id = v_invite.company_id
      AND role = 'admin'
    LIMIT 1;

    INSERT INTO public.company_members (
        company_id,
        user_id,
        role,
        invited_by,
        assigned_admin_id
    ) VALUES (
        v_invite.company_id,
        v_user_id,
        v_invite.role,
        v_invite.invited_by_user_id,
        COALESCE(v_admin_id, v_invite.invited_by_user_id)
    );

    v_latency_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_invite.sent_at))::INTEGER);

    INSERT INTO public.invite_events (
        event_type,
        company_id,
        invite_email_hash,
        invited_by_user_id,
        latency_seconds,
        occurred_at
    ) VALUES (
        'invite_accepted',
        v_invite.company_id,
        public.hash_invite_email(v_invite_email),
        v_invite.invited_by_user_id,
        v_latency_seconds,
        v_now
    );

    DELETE FROM public.company_invites
    WHERE id = v_invite.id;

    RETURN jsonb_build_object(
        'success', true,
        'company_id', v_invite.company_id,
        'user_id', v_user_id,
        'role', v_invite.role
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_company_invite(UUID) TO authenticated, anon;

COMMIT;
