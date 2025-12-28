-- Phase 3 hardening: idempotent override expiration audits
-- Feature IDs: inventory.entitlements.company_tier_expiration_audit

BEGIN;

ALTER TABLE public.company_tier_overrides
    ADD COLUMN IF NOT EXISTS expired_audited_at TIMESTAMPTZ;

COMMENT ON COLUMN public.company_tier_overrides.expired_audited_at IS
    'Timestamp when override expiration audit event was recorded.';

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
    v_updated_id UUID := NULL;
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
          AND expired_audited_at IS NULL
        ORDER BY ends_at ASC
    LOOP
        v_duration := EXTRACT(EPOCH FROM (v_row.ends_at - v_row.starts_at))::INTEGER;

        UPDATE public.company_tier_overrides
        SET revoked_at = v_row.ends_at,
            expired_audited_at = now()
        WHERE id = v_row.id
          AND revoked_at IS NULL
          AND expired_audited_at IS NULL
        RETURNING id INTO v_updated_id;

        IF v_updated_id IS NULL THEN
            CONTINUE;
        END IF;

        v_new_effective := public.effective_company_tier(p_company_id);

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
        v_updated_id := NULL;
    END LOOP;

    RETURN v_count;
END;
$$;

COMMIT;
