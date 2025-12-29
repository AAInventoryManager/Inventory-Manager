-- Invite tracking schema: ephemeral invites + durable analytics events
-- Feature IDs: inventory.auth.invite_tracking

BEGIN;

-- Operational invites (pending only); rows may be deleted after acceptance.
CREATE TABLE IF NOT EXISTS public.company_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL,
    invited_by_user_id UUID NOT NULL REFERENCES auth.users(id),
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resend_count INTEGER NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL,
    CONSTRAINT company_invites_status_check
        CHECK (status IN ('pending','expired')),
    CONSTRAINT company_invites_expires_after_sent_check
        CHECK (expires_at > sent_at)
);

COMMENT ON TABLE public.company_invites IS
    'Ephemeral operational invite records (pending only); rows may be deleted after acceptance.';

CREATE UNIQUE INDEX IF NOT EXISTS company_invites_pending_unique
    ON public.company_invites(company_id, email)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_company_invites_company_id
    ON public.company_invites(company_id);

CREATE INDEX IF NOT EXISTS idx_company_invites_expires_at
    ON public.company_invites(expires_at);

CREATE INDEX IF NOT EXISTS idx_company_invites_status
    ON public.company_invites(status);

-- Durable, append-only invite events for analytics. No PII stored here.
CREATE TABLE IF NOT EXISTS public.invite_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    company_id UUID NOT NULL,
    invite_email_hash TEXT NOT NULL,
    invited_by_user_id UUID,
    resend_count INTEGER,
    latency_seconds INTEGER,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT invite_events_event_type_check
        CHECK (event_type IN ('invite_sent','invite_resent','invite_accepted','invite_expired'))
);

COMMENT ON TABLE public.invite_events IS
    'Append-only invite analytics events; store only non-PII (hashes), never update or delete rows.';

COMMENT ON COLUMN public.invite_events.invite_email_hash IS
    'One-way hash of the invite email address (raw email must not be stored).';

CREATE INDEX IF NOT EXISTS idx_invite_events_company_id
    ON public.invite_events(company_id);

CREATE INDEX IF NOT EXISTS idx_invite_events_event_type
    ON public.invite_events(event_type);

CREATE INDEX IF NOT EXISTS idx_invite_events_occurred_at
    ON public.invite_events(occurred_at);

COMMIT;
