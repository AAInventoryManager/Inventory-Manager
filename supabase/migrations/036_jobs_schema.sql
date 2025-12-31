-- Jobs schema: lifecycle, planned BOM, and actual consumption

BEGIN;

CREATE TABLE IF NOT EXISTS public.jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'draft',
        'quoted',
        'approved',
        'in_progress',
        'completed',
        'voided'
    )),
    notes TEXT,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.jobs IS
    'Jobs represent planned work that consumes inventory. Inventory impact is governed by status transitions, not row changes.';

COMMENT ON COLUMN public.jobs.status IS
    'Lifecycle state used for approval, reservation, and completion workflows.';

CREATE INDEX IF NOT EXISTS idx_jobs_company_id
    ON public.jobs(company_id);

CREATE INDEX IF NOT EXISTS idx_jobs_status
    ON public.jobs(status);

CREATE TABLE IF NOT EXISTS public.job_bom (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    qty_planned NUMERIC NOT NULL CHECK (qty_planned > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.job_bom IS
    'Planned bill of materials per job. Planned BOM has no inventory impact until job approval.';

CREATE INDEX IF NOT EXISTS idx_job_bom_job_id
    ON public.job_bom(job_id);

CREATE INDEX IF NOT EXISTS idx_job_bom_item_id
    ON public.job_bom(item_id);

CREATE TABLE IF NOT EXISTS public.job_actuals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    qty_used NUMERIC NOT NULL CHECK (qty_used >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.job_actuals IS
    'Actual inventory consumption per job. Inventory is decremented only from actuals at completion.';

CREATE INDEX IF NOT EXISTS idx_job_actuals_job_id
    ON public.job_actuals(job_id);

CREATE INDEX IF NOT EXISTS idx_job_actuals_item_id
    ON public.job_actuals(item_id);

COMMIT;
