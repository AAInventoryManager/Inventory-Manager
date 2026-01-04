-- Derived job readiness evaluation (read-only)

BEGIN;

CREATE OR REPLACE FUNCTION public.get_job_readiness(
    p_company_id UUID,
    p_job_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
    job_id UUID,
    ready BOOLEAN,
    reasons TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF NOT public.check_permission(p_company_id, 'items:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    RETURN QUERY
    WITH base_jobs AS (
        SELECT id, status
        FROM public.jobs
        WHERE company_id = p_company_id
          AND (
            p_job_ids IS NULL
            OR COALESCE(array_length(p_job_ids, 1), 0) = 0
            OR id = ANY(p_job_ids)
          )
    ),
    shortfalls AS (
        SELECT job_id, COUNT(*) AS active_shortfalls
        FROM public.shortfalls
        WHERE status = 'active'
        GROUP BY job_id
    ),
    allocation_status AS (
        SELECT b.job_id,
               COUNT(*) FILTER (
                   WHERE COALESCE(a.qty_allocated, 0)::numeric < b.qty_planned
               ) AS incomplete_allocations
        FROM public.job_bom b
        LEFT JOIN public.allocations a
          ON a.job_id = b.job_id
         AND a.item_id = b.item_id
        WHERE b.job_id IN (SELECT id FROM base_jobs)
        GROUP BY b.job_id
    )
    SELECT
        j.id AS job_id,
        (
            j.status = 'approved'
            AND COALESCE(s.active_shortfalls, 0) = 0
            AND COALESCE(a.incomplete_allocations, 0) = 0
        ) AS ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN j.status <> 'approved' THEN 'job_not_approved' END,
            CASE WHEN COALESCE(s.active_shortfalls, 0) > 0 THEN 'shortfall_exists' END,
            CASE WHEN COALESCE(a.incomplete_allocations, 0) > 0 THEN 'allocation_incomplete' END
        ], NULL) AS reasons
    FROM base_jobs j
    LEFT JOIN shortfalls s ON s.job_id = j.id
    LEFT JOIN allocation_status a ON a.job_id = j.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_job_readiness(UUID, UUID[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
