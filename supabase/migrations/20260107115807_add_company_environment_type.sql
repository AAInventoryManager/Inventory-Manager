-- Add environment_type discipline to companies and update analytics filters

BEGIN;

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS environment_type TEXT NOT NULL DEFAULT 'production',
  ADD COLUMN IF NOT EXISTS cleanup_eligible BOOLEAN NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'companies_environment_type_check'
  ) THEN
    ALTER TABLE public.companies
      ADD CONSTRAINT companies_environment_type_check
      CHECK (environment_type IN ('production','internal_test','demo','sandbox'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_companies_environment_type ON public.companies(environment_type);

-- Update get_my_companies to include environment_type
DROP FUNCTION IF EXISTS public.get_my_companies(BOOLEAN);
CREATE OR REPLACE FUNCTION public.get_my_companies(p_include_non_production BOOLEAN DEFAULT false)
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    company_type TEXT,
    environment_type TEXT,
    cleanup_eligible BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_include_non_production BOOLEAN := COALESCE(p_include_non_production, false);
BEGIN
    IF public.is_super_user() THEN
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            'super_user'::text,
            true,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state,
            c.company_type::text,
            c.environment_type::text,
            c.cleanup_eligible
        FROM public.companies c
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE c.is_active = true
          AND (c.company_type = 'production' OR v_include_non_production)
        ORDER BY c.name;
    ELSE
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            cm.role,
            cm.is_super_user,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state,
            c.company_type::text,
            c.environment_type::text,
            c.cleanup_eligible
        FROM public.companies c
        JOIN public.company_members cm ON cm.company_id = c.id
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE cm.user_id = auth.uid()
          AND c.is_active = true
          AND c.company_type = 'production'
        ORDER BY c.name;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_companies(BOOLEAN) TO authenticated;

-- Update advanced company switcher to support environment_type and metrics
DROP FUNCTION IF EXISTS public.get_company_switcher_companies(TEXT, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION public.get_company_switcher_companies(
    p_search TEXT DEFAULT NULL,
    p_company_type TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50,
    p_environment_type TEXT DEFAULT NULL
)
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    inventory_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    company_type TEXT,
    environment_type TEXT,
    cleanup_eligible BOOLEAN,
    created_at TIMESTAMPTZ,
    job_count BIGINT,
    po_count BIGINT,
    total_on_hand NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_search TEXT := NULLIF(trim(COALESCE(p_search, '')), '');
    v_type TEXT := NULLIF(trim(lower(COALESCE(p_company_type, ''))), '');
    v_env TEXT := NULLIF(trim(lower(COALESCE(p_environment_type, ''))), '');
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Super user access required';
    END IF;

    IF v_type IS NOT NULL AND v_type NOT IN ('production','sandbox','test','system') THEN
        RAISE EXCEPTION 'Invalid company_type';
    END IF;

    IF v_env IS NOT NULL AND v_env NOT IN ('production','internal_test','demo','sandbox') THEN
        RAISE EXCEPTION 'Invalid environment_type';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.slug,
        'super_user'::text,
        true,
        (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
        (SELECT COUNT(*) FROM public.inventory_items i WHERE i.company_id = c.id AND i.deleted_at IS NULL),
        tier.effective_tier,
        tier.tier_source,
        tier.billing_state,
        c.company_type::text,
        c.environment_type::text,
        c.cleanup_eligible,
        c.created_at,
        (SELECT COUNT(*) FROM public.jobs j WHERE j.company_id = c.id),
        (SELECT COUNT(*) FROM public.purchase_orders po WHERE po.company_id = c.id),
        (SELECT COALESCE(SUM(COALESCE(i.quantity, 0)), 0) FROM public.inventory_items i WHERE i.company_id = c.id AND i.deleted_at IS NULL)
    FROM public.companies c
    CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
    WHERE c.is_active = true
      AND (v_type IS NULL OR c.company_type::text = v_type)
      AND (v_env IS NULL OR c.environment_type::text = v_env)
      AND (
        v_search IS NULL
        OR c.id::text = v_search
        OR c.name ILIKE '%' || v_search || '%'
        OR c.slug ILIKE '%' || v_search || '%'
      )
    ORDER BY c.name
    LIMIT v_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_switcher_companies(TEXT, TEXT, INTEGER, TEXT) TO authenticated;

-- Update provision_company to allow explicit environment_type assignment
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
    BOOLEAN,
    TEXT
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
    p_company_environment TEXT DEFAULT NULL,
    p_environment_type TEXT DEFAULT NULL
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
    v_env_type TEXT := lower(trim(COALESCE(p_environment_type, '')));
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

    IF v_env_type = '' THEN
        v_env_type := 'production';
    END IF;

    IF v_env_type NOT IN ('production','internal_test','demo','sandbox') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid environment_type');
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
    ),
    dupes AS (
        SELECT user_id FROM assignments GROUP BY user_id HAVING COUNT(*) > 1
    ),
    missing AS (
        SELECT a.user_id
        FROM assignments a
        LEFT JOIN auth.users u ON u.id = a.user_id
        WHERE a.user_id IS NOT NULL AND u.id IS NULL
    ),
    invalid AS (
        SELECT role FROM assignments
        WHERE role NOT IN ('admin', 'member', 'viewer')
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

    INSERT INTO public.companies (name, slug, onboarding_state, company_type, environment_type)
    VALUES (v_name, v_slug, 'UNINITIALIZED', v_company_env::public.company_type, v_env_type)
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

GRANT EXECUTE ON FUNCTION public.provision_company(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, BOOLEAN, UUID, TEXT, JSONB, BOOLEAN, TEXT, TEXT) TO authenticated;

-- Platform metrics dashboard RPC (super user only)
CREATE OR REPLACE FUNCTION public.get_platform_dashboard_metrics(
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_days INTEGER;
    v_result JSONB;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_days := GREATEST(COALESCE(p_days, 30), 1);

    SELECT jsonb_build_object(
        'platform', jsonb_build_object(
            'total_companies', (SELECT COUNT(*) FROM public.companies WHERE environment_type = 'production'),
            'total_users', (
                SELECT COUNT(DISTINCT cm.user_id)
                FROM public.company_members cm
                JOIN public.companies c ON c.id = cm.company_id
                WHERE c.environment_type = 'production'
            ),
            'total_items', (
                SELECT COUNT(*)
                FROM public.inventory_items ii
                JOIN public.companies c ON c.id = ii.company_id
                WHERE c.environment_type = 'production'
                  AND ii.deleted_at IS NULL
            ),
            'total_orders', (
                SELECT COUNT(*)
                FROM public.orders o
                JOIN public.companies c ON c.id = o.company_id
                WHERE c.environment_type = 'production'
                  AND o.deleted_at IS NULL
            )
        ),
        'activity', jsonb_build_object(
            'total_actions', (
                SELECT COALESCE(SUM(am.action_count), 0)
                FROM public.action_metrics am
                JOIN public.companies c ON c.id = am.company_id
                WHERE c.environment_type = 'production'
                  AND am.metric_date >= CURRENT_DATE - v_days
            ),
            'active_companies', (
                SELECT COUNT(DISTINCT am.company_id)
                FROM public.action_metrics am
                JOIN public.companies c ON c.id = am.company_id
                WHERE c.environment_type = 'production'
                  AND am.metric_date >= CURRENT_DATE - v_days
            ),
            'active_users', (
                SELECT COUNT(DISTINCT am.user_id)
                FROM public.action_metrics am
                JOIN public.companies c ON c.id = am.company_id
                WHERE c.environment_type = 'production'
                  AND am.metric_date >= CURRENT_DATE - v_days
            )
        ),
        'companies', (
            SELECT COALESCE(jsonb_agg(c), '[]'::jsonb)
            FROM (
                SELECT co.id,
                    co.name,
                    (SELECT COUNT(*) FROM public.company_members cm WHERE cm.company_id = co.id) AS member_count,
                    (SELECT COUNT(*) FROM public.inventory_items ii WHERE ii.company_id = co.id AND ii.deleted_at IS NULL) AS item_count,
                    COALESCE((
                        SELECT SUM(action_count) FROM public.action_metrics am
                        WHERE am.company_id = co.id
                          AND am.metric_date >= CURRENT_DATE - v_days
                    ), 0) AS recent_actions
                FROM public.companies co
                WHERE co.environment_type = 'production'
                ORDER BY recent_actions DESC
                LIMIT 20
            ) c
        ),
        'daily', (
            SELECT COALESCE(jsonb_agg(d ORDER BY d.metric_date DESC), '[]'::jsonb)
            FROM (
                SELECT am.metric_date,
                    SUM(am.action_count) AS total_actions,
                    COUNT(DISTINCT am.company_id) AS active_companies
                FROM public.action_metrics am
                JOIN public.companies c ON c.id = am.company_id
                WHERE c.environment_type = 'production'
                  AND am.metric_date >= CURRENT_DATE - v_days
                GROUP BY am.metric_date
            ) d
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

-- Platform metrics summary RPC
CREATE OR REPLACE FUNCTION public.get_platform_metrics()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;

    RETURN json_build_object(
        'total_companies', (SELECT COUNT(*) FROM public.companies WHERE environment_type = 'production'),
        'active_companies', (SELECT COUNT(*) FROM public.companies WHERE is_active = true AND environment_type = 'production'),
        'total_users', (
            SELECT COUNT(DISTINCT cm.user_id)
            FROM public.company_members cm
            JOIN public.companies c ON c.id = cm.company_id
            WHERE c.environment_type = 'production'
        ),
        'total_items', (
            SELECT COUNT(*)
            FROM public.inventory_items ii
            JOIN public.companies c ON c.id = ii.company_id
            WHERE c.environment_type = 'production'
              AND ii.deleted_at IS NULL
        ),
        'total_deleted_items', (
            SELECT COUNT(*)
            FROM public.inventory_items ii
            JOIN public.companies c ON c.id = ii.company_id
            WHERE c.environment_type = 'production'
              AND ii.deleted_at IS NOT NULL
        ),
        'companies_breakdown', (
            SELECT json_agg(row_to_json(t))
            FROM (
                SELECT 
                    c.name,
                    (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id) as users,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NULL) as items,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NOT NULL) as deleted_items
                FROM public.companies c
                WHERE c.is_active = true
                  AND c.environment_type = 'production'
            ) t
        )
    );
END;
$$;

-- Action metrics RPC
CREATE OR REPLACE FUNCTION public.get_action_metrics(p_company_id UUID DEFAULT NULL, p_days INTEGER DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;

    IF p_company_id IS NOT NULL THEN
        IF NOT public.has_tier_access(p_company_id, 'professional') THEN
            RETURN json_build_object('error', 'Feature not available for current plan');
        END IF;
    END IF;

    RETURN json_build_object(
        'period_days', p_days,
        'total_deletes', (
            SELECT COALESCE(SUM(am.action_count), 0)
            FROM public.action_metrics am
            JOIN public.companies c ON c.id = am.company_id
            WHERE c.environment_type = 'production'
              AND (p_company_id IS NULL OR am.company_id = p_company_id)
              AND am.metric_date >= CURRENT_DATE - p_days
              AND am.action_type = 'delete'
        ),
        'total_updates', (
            SELECT COALESCE(SUM(am.action_count), 0)
            FROM public.action_metrics am
            JOIN public.companies c ON c.id = am.company_id
            WHERE c.environment_type = 'production'
              AND (p_company_id IS NULL OR am.company_id = p_company_id)
              AND am.metric_date >= CURRENT_DATE - p_days
              AND am.action_type = 'update'
        ),
        'total_restores', (
            SELECT COALESCE(SUM(am.action_count), 0)
            FROM public.action_metrics am
            JOIN public.companies c ON c.id = am.company_id
            WHERE c.environment_type = 'production'
              AND (p_company_id IS NULL OR am.company_id = p_company_id)
              AND am.metric_date >= CURRENT_DATE - p_days
              AND am.action_type = 'restore'
        ),
        'quantity_removed', (
            SELECT COALESCE(SUM(am.quantity_removed), 0)
            FROM public.action_metrics am
            JOIN public.companies c ON c.id = am.company_id
            WHERE c.environment_type = 'production'
              AND (p_company_id IS NULL OR am.company_id = p_company_id)
              AND am.metric_date >= CURRENT_DATE - p_days
        )
    );
END;
$$;

COMMIT;
