-- Phase 3: company tier overrides with time windows
-- Feature IDs: inventory.entitlements.company_tier_overrides

BEGIN;

-- Base subscription tier stored on companies
ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS base_subscription_tier TEXT NOT NULL DEFAULT 'starter';

ALTER TABLE public.companies
    DROP CONSTRAINT IF EXISTS companies_base_subscription_tier_check;

ALTER TABLE public.companies
    ADD CONSTRAINT companies_base_subscription_tier_check
    CHECK (base_subscription_tier IN ('starter','professional','business','enterprise')) NOT VALID;

ALTER TABLE public.companies
    VALIDATE CONSTRAINT companies_base_subscription_tier_check;

-- Backfill base_subscription_tier from billing if present, else from settings.tier
WITH latest_sub AS (
    SELECT
        bs.company_id,
        bpm.tier,
        ROW_NUMBER() OVER (PARTITION BY bs.company_id ORDER BY bs.updated_at DESC NULLS LAST) AS rn
    FROM public.billing_subscriptions bs
    JOIN public.billing_price_map bpm
      ON bpm.provider = bs.provider
     AND bpm.price_id = bs.price_id
     AND bpm.is_active = true
    WHERE bs.status IN ('active','trial','grace')
      AND (
        bs.status <> 'trial'
        OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
      )
      AND (
        bs.status <> 'grace'
        OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
      )
)
UPDATE public.companies c
SET base_subscription_tier = ls.tier
FROM latest_sub ls
WHERE c.id = ls.company_id
  AND ls.rn = 1;

UPDATE public.companies c
SET base_subscription_tier = lower(trim(c.settings->>'tier'))
WHERE lower(trim(c.settings->>'tier')) IN ('starter','professional','business','enterprise')
  AND NOT EXISTS (
      SELECT 1
      FROM public.billing_subscriptions bs
      JOIN public.billing_price_map bpm
        ON bpm.provider = bs.provider
       AND bpm.price_id = bs.price_id
       AND bpm.is_active = true
      WHERE bs.company_id = c.id
        AND bs.status IN ('active','trial','grace')
        AND (
          bs.status <> 'trial'
          OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
        )
        AND (
          bs.status <> 'grace'
          OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
        )
  );

UPDATE public.companies
SET base_subscription_tier = 'starter'
WHERE base_subscription_tier IS NULL
   OR base_subscription_tier NOT IN ('starter','professional','business','enterprise');

-- Override history table
CREATE TABLE IF NOT EXISTS public.company_tier_overrides (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    override_tier TEXT NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ends_at TIMESTAMPTZ NULL,
    revoked_at TIMESTAMPTZ NULL,
    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT company_tier_overrides_tier_check
        CHECK (override_tier IN ('starter','professional','business','enterprise')),
    CONSTRAINT company_tier_overrides_window_check
        CHECK (ends_at IS NULL OR ends_at > starts_at)
);

COMMENT ON TABLE public.company_tier_overrides IS 'Append-only history of company tier overrides (time-windowed).';

CREATE INDEX IF NOT EXISTS idx_company_tier_overrides_company
    ON public.company_tier_overrides(company_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_company_tier_overrides_active_lookup
    ON public.company_tier_overrides(company_id, starts_at, ends_at)
    WHERE revoked_at IS NULL;

-- Prevent overlapping non-revoked override windows per company
CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE public.company_tier_overrides
    DROP CONSTRAINT IF EXISTS company_tier_overrides_no_overlap;

ALTER TABLE public.company_tier_overrides
    ADD CONSTRAINT company_tier_overrides_no_overlap
    EXCLUDE USING gist (
        company_id WITH =,
        tstzrange(starts_at, COALESCE(ends_at, 'infinity'::timestamptz)) WITH &&
    )
    WHERE (revoked_at IS NULL);

-- Partial unique index to guard a single indefinite override per company
CREATE UNIQUE INDEX IF NOT EXISTS company_tier_overrides_active_unique
    ON public.company_tier_overrides(company_id)
    WHERE revoked_at IS NULL AND ends_at IS NULL;

-- Migrate existing company-level overrides when present
INSERT INTO public.company_tier_overrides (
    company_id,
    override_tier,
    starts_at,
    ends_at,
    revoked_at,
    created_by,
    created_at
)
SELECT
    c.id,
    c.tier_override::text,
    COALESCE(c.tier_override_set_at, now()),
    NULL,
    NULL,
    COALESCE(
        c.tier_override_set_by,
        (SELECT cm.user_id FROM public.company_members cm WHERE cm.company_id = c.id AND cm.is_super_user LIMIT 1),
        (SELECT cm.user_id FROM public.company_members cm WHERE cm.company_id = c.id ORDER BY cm.created_at LIMIT 1)
    ),
    COALESCE(c.tier_override_set_at, now())
FROM public.companies c
WHERE c.tier_override IS NOT NULL
  AND COALESCE(
        c.tier_override_set_by,
        (SELECT cm.user_id FROM public.company_members cm WHERE cm.company_id = c.id AND cm.is_super_user LIMIT 1),
        (SELECT cm.user_id FROM public.company_members cm WHERE cm.company_id = c.id ORDER BY cm.created_at LIMIT 1)
    ) IS NOT NULL;

ALTER TABLE public.company_tier_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.company_tier_overrides FROM anon, authenticated, public;

COMMIT;
