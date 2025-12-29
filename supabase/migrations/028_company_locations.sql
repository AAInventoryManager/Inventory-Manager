-- Company locations table (Shipping/Receiving)

BEGIN;

CREATE TABLE IF NOT EXISTS public.company_locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    location_type TEXT NOT NULL CHECK (location_type IN ('warehouse','yard','office','job_site','other')),
    address_line1 TEXT NOT NULL,
    address_line2 TEXT,
    city TEXT NOT NULL,
    state_region TEXT NOT NULL,
    postal_code TEXT NOT NULL,
    country_code CHAR(2) NOT NULL CHECK (country_code = upper(country_code) AND country_code ~ '^[A-Z]{2}$'),
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_default_ship_to BOOLEAN NOT NULL DEFAULT false,
    is_default_receive_at BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.company_locations IS
    'Company operational locations for shipping/receiving. Defaults are enforced at the schema level; archival via is_active=false is preferred over delete; deletions with references are restricted at the logic layer.';

COMMENT ON COLUMN public.company_locations.is_default_ship_to IS
    'Default ship-to location per company; enforced via partial unique index when active.';

COMMENT ON COLUMN public.company_locations.is_default_receive_at IS
    'Default receive-at location per company; enforced via partial unique index when active.';

COMMENT ON COLUMN public.company_locations.is_active IS
    'Soft-archive flag; inactive locations should not be used for new activity.';

CREATE INDEX IF NOT EXISTS idx_company_locations_company_id
    ON public.company_locations(company_id);

CREATE INDEX IF NOT EXISTS idx_company_locations_is_active
    ON public.company_locations(is_active);

CREATE INDEX IF NOT EXISTS idx_company_locations_location_type
    ON public.company_locations(location_type);

CREATE UNIQUE INDEX IF NOT EXISTS idx_company_locations_default_ship_to
    ON public.company_locations(company_id)
    WHERE is_default_ship_to = true AND is_active = true;

CREATE UNIQUE INDEX IF NOT EXISTS idx_company_locations_default_receive_at
    ON public.company_locations(company_id)
    WHERE is_default_receive_at = true AND is_active = true;

COMMIT;
