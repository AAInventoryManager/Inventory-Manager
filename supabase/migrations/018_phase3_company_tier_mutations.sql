-- Phase 3: super_user tier mutation APIs + audit events
-- Feature IDs: inventory.entitlements.company_tier_mutations

BEGIN;

-- Helper: audit entitlement events
CREATE OR REPLACE FUNCTION public.log_entitlement_audit_event(
    p_event_name TEXT,
    p_company_id UUID,
    p_record_id UUID,
    p_previous_effective_tier TEXT,
    p_new_effective_tier TEXT,
    p_override_duration_seconds INTEGER,
    p_actor_user_id UUID
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
        'entitlement_events',
        COALESCE(p_record_id, p_company_id),
        p_company_id,
        p_actor_user_id,
        jsonb_build_object(
            'event_name', p_event_name,
            'previous_effective_tier', p_previous_effective_tier,
            'new_effective_tier', p_new_effective_tier,
            'override_duration_seconds', p_override_duration_seconds,
            'timestamp', now()
        )
    );
END;
$$;

-- Helper: mark expired overrides and emit audit events
CREATE OR REPLACE FUNCTION public.expire_company_tier_overrides(p_company_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
    v_count INTEGER := 0;
    v_row RECORD;
    v_new_effective TEXT := 'starter';
    v_duration INTEGER := NULL;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT id, override_tier, starts_at, ends_at
        FROM public.company_tier_overrides
        WHERE company_id = p_company_id
          AND revoked_at IS NULL
          AND ends_at IS NOT NULL
          AND ends_at <= now()
        ORDER BY ends_at ASC
    LOOP
        v_duration := EXTRACT(EPOCH FROM (v_row.ends_at - v_row.starts_at))::INTEGER;
        v_new_effective := public.effective_company_tier(p_company_id);

        UPDATE public.company_tier_overrides
        SET revoked_at = v_row.ends_at
        WHERE id = v_row.id AND revoked_at IS NULL;

        PERFORM public.log_entitlement_audit_event(
            'entitlement.company_tier.override_expired',
            p_company_id,
            v_row.id,
            lower(trim(v_row.override_tier)),
            v_new_effective,
            v_duration,
            NULL
        );

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

-- Super user: set base subscription tier
CREATE OR REPLACE FUNCTION public.set_company_base_tier(
    p_company_id UUID,
    p_new_base_tier TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_new_base TEXT := lower(trim(COALESCE(p_new_base_tier, '')));
    v_prev_effective TEXT := NULL;
    v_new_effective TEXT := NULL;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_new_base NOT IN ('starter','professional','business','enterprise') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid base tier');
    END IF;

    PERFORM public.expire_company_tier_overrides(p_company_id);
    v_prev_effective := public.effective_company_tier(p_company_id);

    UPDATE public.companies
    SET base_subscription_tier = v_new_base,
        updated_at = now()
    WHERE id = p_company_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company not found');
    END IF;

    v_new_effective := public.effective_company_tier(p_company_id);

    PERFORM public.log_entitlement_audit_event(
        'entitlement.company_tier.base_changed',
        p_company_id,
        p_company_id,
        v_prev_effective,
        v_new_effective,
        NULL,
        auth.uid()
    );

    RETURN jsonb_build_object(
        'success', true,
        'effective_tier', v_new_effective
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_company_base_tier(UUID, TEXT) TO authenticated;

-- Super user: grant a time-limited override
CREATE OR REPLACE FUNCTION public.grant_company_tier_override(
    p_company_id UUID,
    p_override_tier TEXT,
    p_ends_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_override TEXT := lower(trim(COALESCE(p_override_tier, '')));
    v_start TIMESTAMPTZ := now();
    v_prev_effective TEXT := NULL;
    v_new_effective TEXT := NULL;
    v_overlap UUID := NULL;
    v_override_id UUID := NULL;
    v_duration INTEGER := NULL;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_override NOT IN ('starter','professional','business','enterprise') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid override tier');
    END IF;

    IF p_ends_at IS NOT NULL AND p_ends_at <= v_start THEN
        RETURN jsonb_build_object('success', false, 'error', 'Override end must be in the future');
    END IF;

    PERFORM public.expire_company_tier_overrides(p_company_id);
    v_prev_effective := public.effective_company_tier(p_company_id);

    SELECT cto.id
    INTO v_overlap
    FROM public.company_tier_overrides cto
    WHERE cto.company_id = p_company_id
      AND cto.revoked_at IS NULL
      AND tstzrange(cto.starts_at, COALESCE(cto.ends_at, 'infinity'::timestamptz))
          && tstzrange(v_start, COALESCE(p_ends_at, 'infinity'::timestamptz))
    LIMIT 1;

    IF v_overlap IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Active override already exists');
    END IF;

    INSERT INTO public.company_tier_overrides (
        company_id,
        override_tier,
        starts_at,
        ends_at,
        revoked_at,
        created_by,
        created_at
    ) VALUES (
        p_company_id,
        v_override,
        v_start,
        p_ends_at,
        NULL,
        auth.uid(),
        now()
    ) RETURNING id INTO v_override_id;

    v_new_effective := public.effective_company_tier(p_company_id);
    IF p_ends_at IS NOT NULL THEN
        v_duration := EXTRACT(EPOCH FROM (p_ends_at - v_start))::INTEGER;
    END IF;

    PERFORM public.log_entitlement_audit_event(
        'entitlement.company_tier.override_granted',
        p_company_id,
        v_override_id,
        v_prev_effective,
        v_new_effective,
        v_duration,
        auth.uid()
    );

    RETURN jsonb_build_object(
        'success', true,
        'override_id', v_override_id,
        'effective_tier', v_new_effective
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.grant_company_tier_override(UUID, TEXT, TIMESTAMPTZ) TO authenticated;

-- Super user: revoke active override
CREATE OR REPLACE FUNCTION public.revoke_company_tier_override(
    p_company_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_prev_effective TEXT := NULL;
    v_new_effective TEXT := NULL;
    v_row RECORD;
    v_remaining INTEGER := NULL;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    PERFORM public.expire_company_tier_overrides(p_company_id);
    v_prev_effective := public.effective_company_tier(p_company_id);

    SELECT id, override_tier, ends_at
    INTO v_row
    FROM public.company_tier_overrides
    WHERE company_id = p_company_id
      AND revoked_at IS NULL
      AND starts_at <= now()
      AND (ends_at IS NULL OR now() < ends_at)
    ORDER BY starts_at DESC, created_at DESC
    LIMIT 1;

    IF v_row IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No active override');
    END IF;

    UPDATE public.company_tier_overrides
    SET revoked_at = now()
    WHERE id = v_row.id AND revoked_at IS NULL;

    IF v_row.ends_at IS NOT NULL THEN
        v_remaining := GREATEST(0, EXTRACT(EPOCH FROM (v_row.ends_at - now()))::INTEGER);
    END IF;

    v_new_effective := public.effective_company_tier(p_company_id);

    PERFORM public.log_entitlement_audit_event(
        'entitlement.company_tier.override_revoked',
        p_company_id,
        v_row.id,
        v_prev_effective,
        v_new_effective,
        v_remaining,
        auth.uid()
    );

    RETURN jsonb_build_object(
        'success', true,
        'effective_tier', v_new_effective
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.revoke_company_tier_override(UUID) TO authenticated;

-- Backward-compatible wrapper (no expiration support)
CREATE OR REPLACE FUNCTION public.set_company_tier_override(
    p_company_id UUID,
    p_tier TEXT,
    p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_tier IS NULL OR length(trim(p_tier)) = 0 THEN
        RETURN public.revoke_company_tier_override(p_company_id);
    END IF;

    RETURN public.grant_company_tier_override(p_company_id, p_tier, NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_company_tier_override(UUID, TEXT, TEXT) TO authenticated;

-- Update tier details to sync expiration for super users
CREATE OR REPLACE FUNCTION public.get_company_tier_details(p_company_id UUID)
RETURNS TABLE (
    base_tier TEXT,
    override_tier TEXT,
    effective_tier TEXT,
    tier_source TEXT,
    override_starts_at TIMESTAMPTZ,
    override_ends_at TIMESTAMPTZ,
    override_revoked_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
    v_res RECORD;
    v_override RECORD;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    PERFORM public.expire_company_tier_overrides(p_company_id);
    SELECT * INTO v_res FROM public.resolve_company_tier(p_company_id);

    SELECT cto.override_tier, cto.starts_at, cto.ends_at, cto.revoked_at
    INTO v_override
    FROM public.company_tier_overrides cto
    WHERE cto.company_id = p_company_id
      AND cto.revoked_at IS NULL
      AND cto.starts_at <= now()
      AND (cto.ends_at IS NULL OR now() < cto.ends_at)
    ORDER BY cto.starts_at DESC, cto.created_at DESC
    LIMIT 1;

    RETURN QUERY SELECT
        v_res.subscription_tier,
        COALESCE(v_override.override_tier, v_res.override_tier),
        v_res.effective_tier,
        v_res.tier_source,
        v_override.starts_at,
        v_override.ends_at,
        v_override.revoked_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier_details(UUID) TO authenticated;

COMMIT;
