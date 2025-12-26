-- Phase 2: billing subscriptions and tier resolution
-- Feature IDs: inventory.billing.subscriptions, inventory.billing.webhooks

BEGIN;

CREATE TABLE IF NOT EXISTS public.billing_price_map (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT NOT NULL DEFAULT 'stripe',
    price_id TEXT NOT NULL,
    tier TEXT NOT NULL CHECK (tier IN ('starter','professional','business','enterprise')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(provider, price_id)
);

CREATE INDEX IF NOT EXISTS idx_billing_price_map_tier
    ON public.billing_price_map(tier);

CREATE TABLE IF NOT EXISTS public.billing_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    provider TEXT NOT NULL DEFAULT 'stripe',
    customer_id TEXT,
    subscription_id TEXT,
    price_id TEXT,
    status TEXT NOT NULL CHECK (status IN ('active','trial','grace','inactive')),
    provider_status TEXT,
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    trial_start TIMESTAMPTZ,
    trial_end TIMESTAMPTZ,
    grace_start TIMESTAMPTZ,
    grace_end TIMESTAMPTZ,
    cancel_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    last_event_id TEXT,
    last_event_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (status <> 'trial' OR trial_end IS NOT NULL),
    CHECK (status <> 'grace' OR grace_end IS NOT NULL),
    CHECK (status NOT IN ('active','trial','grace') OR price_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_billing_subscriptions_company
    ON public.billing_subscriptions(company_id);
CREATE INDEX IF NOT EXISTS idx_billing_subscriptions_status
    ON public.billing_subscriptions(status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_subscriptions_provider_id
    ON public.billing_subscriptions(provider, subscription_id)
    WHERE subscription_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_subscriptions_company_active
    ON public.billing_subscriptions(company_id)
    WHERE status IN ('active','trial','grace');

ALTER TABLE public.billing_price_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_subscriptions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.billing_price_map FROM anon, authenticated;
REVOKE ALL ON TABLE public.billing_subscriptions FROM anon, authenticated;
REVOKE ALL ON TABLE public.billing_price_map FROM public;
REVOKE ALL ON TABLE public.billing_subscriptions FROM public;

-- Company tier helper (defaults to starter when missing/invalid/ambiguous)
CREATE OR REPLACE FUNCTION public.get_company_tier(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_tier TEXT;
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM public.billing_subscriptions bs
    WHERE bs.company_id = p_company_id
      AND bs.status IN ('active','trial','grace')
      AND (
        bs.status <> 'trial'
        OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
      )
      AND (
        bs.status <> 'grace'
        OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
      );

    IF v_count IS NULL OR v_count = 0 THEN
        RETURN 'starter';
    END IF;

    IF v_count > 1 THEN
        RETURN 'starter';
    END IF;

    SELECT bpm.tier
    INTO v_tier
    FROM public.billing_subscriptions bs
    JOIN public.billing_price_map bpm
      ON bpm.provider = bs.provider
     AND bpm.price_id = bs.price_id
     AND bpm.is_active = true
    WHERE bs.company_id = p_company_id
      AND bs.status IN ('active','trial','grace')
      AND (
        bs.status <> 'trial'
        OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
      )
      AND (
        bs.status <> 'grace'
        OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
      )
    ORDER BY bs.updated_at DESC NULLS LAST
    LIMIT 1;

    IF v_tier IS NULL OR v_tier NOT IN ('starter','professional','business','enterprise') THEN
        RETURN 'starter';
    END IF;

    RETURN v_tier;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier(UUID) TO authenticated;

COMMIT;
