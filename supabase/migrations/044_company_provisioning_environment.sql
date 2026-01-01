-- Update provision_company signature to support environment classification

BEGIN;

DROP FUNCTION IF EXISTS public.provision_company(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    BOOLEAN,
    UUID,
    TEXT,
    JSONB,
    BOOLEAN
);

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
    p_include_actor_as_admin BOOLEAN DEFAULT true,
    p_company_environment TEXT DEFAULT NULL
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
    v_company_env TEXT := lower(trim(COALESCE(p_company_environment, '')));
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

    IF v_company_env = '' THEN
        v_company_env := CASE WHEN p_seed_inventory THEN 'test' ELSE 'production' END;
    END IF;

    IF v_company_env NOT IN ('production', 'test') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid company environment');
    END IF;

    IF p_seed_inventory AND v_company_env <> 'test' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Seed inventory requires test environment');
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

    INSERT INTO public.companies (name, slug, onboarding_state, company_type)
    VALUES (v_name, v_slug, 'UNINITIALIZED', v_company_env::public.company_type)
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

GRANT EXECUTE ON FUNCTION public.provision_company(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, BOOLEAN, UUID, TEXT, JSONB, BOOLEAN, TEXT) TO authenticated;

COMMIT;
