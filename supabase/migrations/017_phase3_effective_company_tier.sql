-- Phase 3: server-side effective tier resolution
-- Feature IDs: inventory.entitlements.company_tier_resolution

BEGIN;

-- Effective tier resolver (no super_user bypass)
CREATE OR REPLACE FUNCTION public.effective_company_tier(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_override TEXT := NULL;
    v_base TEXT := 'starter';
BEGIN
    IF p_company_id IS NULL THEN
        RETURN 'starter';
    END IF;

    SELECT cto.override_tier
    INTO v_override
    FROM public.company_tier_overrides cto
    WHERE cto.company_id = p_company_id
      AND cto.revoked_at IS NULL
      AND cto.starts_at <= now()
      AND (cto.ends_at IS NULL OR now() < cto.ends_at)
    ORDER BY cto.starts_at DESC, cto.created_at DESC
    LIMIT 1;

    IF v_override IS NOT NULL THEN
        RETURN lower(trim(v_override));
    END IF;

    SELECT c.base_subscription_tier
    INTO v_base
    FROM public.companies c
    WHERE c.id = p_company_id;

    v_base := lower(trim(COALESCE(v_base, 'starter')));
    IF v_base NOT IN ('starter','professional','business','enterprise') THEN
        v_base := 'starter';
    END IF;

    RETURN v_base;
END;
$$;

GRANT EXECUTE ON FUNCTION public.effective_company_tier(UUID) TO authenticated;

-- Base + override resolution details
CREATE OR REPLACE FUNCTION public.resolve_company_tier(p_company_id UUID)
RETURNS TABLE (
    subscription_tier TEXT,
    override_tier TEXT,
    effective_tier TEXT,
    tier_source TEXT,
    billing_state TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_base TEXT := 'starter';
    v_override TEXT := NULL;
    v_effective TEXT := 'starter';
    v_source TEXT := 'base';
BEGIN
    IF p_company_id IS NULL THEN
        RETURN QUERY SELECT 'starter'::text, NULL::text, 'starter'::text, 'base'::text, 'none'::text;
        RETURN;
    END IF;

    SELECT c.base_subscription_tier
    INTO v_base
    FROM public.companies c
    WHERE c.id = p_company_id;

    v_base := lower(trim(COALESCE(v_base, 'starter')));
    IF v_base NOT IN ('starter','professional','business','enterprise') THEN
        v_base := 'starter';
    END IF;

    SELECT cto.override_tier
    INTO v_override
    FROM public.company_tier_overrides cto
    WHERE cto.company_id = p_company_id
      AND cto.revoked_at IS NULL
      AND cto.starts_at <= now()
      AND (cto.ends_at IS NULL OR now() < cto.ends_at)
    ORDER BY cto.starts_at DESC, cto.created_at DESC
    LIMIT 1;

    IF v_override IS NOT NULL THEN
        v_effective := lower(trim(v_override));
        v_source := 'override';
    ELSE
        v_effective := v_base;
        v_source := 'base';
    END IF;

    RETURN QUERY SELECT v_base, v_override, v_effective, v_source, 'none'::text;
END;
$$;

-- Tier resolution with super_user bypass
DROP FUNCTION IF EXISTS public.get_company_tier(UUID);
CREATE OR REPLACE FUNCTION public.get_company_tier(p_company_id UUID)
RETURNS TABLE (
    effective_tier TEXT,
    tier_source TEXT,
    billing_state TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_res RECORD;
BEGIN
    SELECT * INTO v_res FROM public.resolve_company_tier(p_company_id);

    IF public.is_super_user() THEN
        RETURN QUERY SELECT 'enterprise'::text, 'super_user'::text, 'none'::text;
        RETURN;
    END IF;

    RETURN QUERY SELECT v_res.effective_tier, v_res.tier_source, v_res.billing_state;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier(UUID) TO authenticated;

-- Super user tier details for administration
DROP FUNCTION IF EXISTS public.get_company_tier_details(UUID);
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
STABLE
SET search_path = public
AS $$
DECLARE
    v_res RECORD;
    v_override RECORD;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

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

-- Tier access helper with super user bypass
CREATE OR REPLACE FUNCTION public.has_tier_access(p_company_id UUID, p_required_tier TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_required_rank INTEGER := 0;
    v_effective TEXT := NULL;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN false;
    END IF;

    IF public.is_super_user() THEN
        RETURN true;
    END IF;

    v_required_rank := public.tier_rank(p_required_tier);
    IF v_required_rank = 0 THEN
        RETURN false;
    END IF;

    v_effective := public.effective_company_tier(p_company_id);

    RETURN public.tier_rank(v_effective) >= v_required_rank;
END;
$$;

GRANT EXECUTE ON FUNCTION public.has_tier_access(UUID, TEXT) TO authenticated;

COMMIT;
