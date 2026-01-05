-- Job item allocations for demand visibility

BEGIN;

CREATE TABLE IF NOT EXISTS public.job_item_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    qty_required INTEGER NOT NULL CHECK (qty_required >= 0),
    qty_allocated INTEGER NOT NULL DEFAULT 0 CHECK (qty_allocated >= 0),
    status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','approved','active','completed','cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_item_allocations_company_id
    ON public.job_item_allocations(company_id);

CREATE INDEX IF NOT EXISTS idx_job_item_allocations_item_id
    ON public.job_item_allocations(item_id);

CREATE INDEX IF NOT EXISTS idx_job_item_allocations_job_id
    ON public.job_item_allocations(job_id);

CREATE INDEX IF NOT EXISTS idx_job_item_allocations_company_item
    ON public.job_item_allocations(company_id, item_id);

CREATE INDEX IF NOT EXISTS idx_job_item_allocations_company_item_status
    ON public.job_item_allocations(company_id, item_id, status);

ALTER TABLE public.job_item_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "job_item_allocations_select" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_select"
    ON public.job_item_allocations FOR SELECT
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "job_item_allocations_insert" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_insert"
    ON public.job_item_allocations FOR INSERT
    TO authenticated
    WITH CHECK (
        company_id IN (SELECT public.get_user_company_ids())
        AND qty_required >= 0
    );

DROP POLICY IF EXISTS "job_item_allocations_update" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_update"
    ON public.job_item_allocations FOR UPDATE
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()))
    WITH CHECK (
        company_id IN (SELECT public.get_user_company_ids())
        AND qty_allocated <= qty_required
    );

DROP POLICY IF EXISTS "job_item_allocations_delete" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_delete"
    ON public.job_item_allocations FOR DELETE
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP TRIGGER IF EXISTS update_job_item_allocations_updated_at ON public.job_item_allocations;
CREATE TRIGGER update_job_item_allocations_updated_at
    BEFORE UPDATE ON public.job_item_allocations
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE OR REPLACE VIEW public.inventory_committed_by_item AS
SELECT
    company_id,
    item_id,
    SUM(qty_required) AS committed_qty
FROM public.job_item_allocations
WHERE status IN ('approved','active')
GROUP BY company_id, item_id;

COMMIT;
