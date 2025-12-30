-- Add company onboarding state

BEGIN;

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS onboarding_state TEXT NOT NULL DEFAULT 'UNINITIALIZED'
    CHECK (onboarding_state IN (
        'UNINITIALIZED',
        'SUBSCRIPTION_ACTIVE',
        'COMPANY_PROFILE_COMPLETE',
        'LOCATIONS_CONFIGURED',
        'USERS_INVITED',
        'ONBOARDING_COMPLETE'
    ));

COMMENT ON COLUMN public.companies.onboarding_state IS
    'Company-scoped onboarding state; transitions are server-side only; UI must reflect this state and must not mutate it directly.';

CREATE INDEX IF NOT EXISTS idx_companies_onboarding_state
    ON public.companies(onboarding_state);

COMMIT;
