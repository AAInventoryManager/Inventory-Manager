-- Add job_number + company counter and wire job creation

BEGIN;

ALTER TABLE public.jobs
    ADD COLUMN IF NOT EXISTS job_number TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_company_job_number
    ON public.jobs(company_id, job_number);

CREATE TABLE IF NOT EXISTS public.company_counters (
    company_id UUID PRIMARY KEY REFERENCES public.companies(id) ON DELETE CASCADE,
    next_job_number INTEGER NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.company_counters ENABLE ROW LEVEL SECURITY;

INSERT INTO public.company_counters (company_id, next_job_number)
SELECT id, 1
FROM public.companies
ON CONFLICT (company_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.next_job_number(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_next INTEGER;
    v_job_number TEXT;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    INSERT INTO public.company_counters (company_id, next_job_number)
    VALUES (p_company_id, 1)
    ON CONFLICT (company_id) DO NOTHING;

    SELECT next_job_number
    INTO v_next
    FROM public.company_counters
    WHERE company_id = p_company_id
    FOR UPDATE;

    IF v_next IS NULL THEN
        v_next := 1;
    END IF;

    v_job_number := format('J-%s-%s', to_char(now(), 'YY'), lpad(v_next::text, 4, '0'));

    UPDATE public.company_counters
    SET next_job_number = v_next + 1,
        updated_at = now()
    WHERE company_id = p_company_id;

    RETURN v_job_number;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_job(
    p_company_id UUID,
    p_name TEXT,
    p_notes TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_job_id UUID;
    v_name TEXT := nullif(trim(p_name), '');
    v_job_number TEXT;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF NOT public.user_can_write(p_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Missing job name';
    END IF;

    v_job_number := public.next_job_number(p_company_id);

    INSERT INTO public.jobs (
        company_id,
        job_number,
        name,
        status,
        notes,
        created_by,
        created_at,
        updated_at
    ) VALUES (
        p_company_id,
        v_job_number,
        v_name,
        'draft',
        p_notes,
        v_actor,
        now(),
        now()
    )
    RETURNING id INTO v_job_id;

    PERFORM public.log_job_event(
        'job_created',
        v_job_id,
        p_company_id,
        v_actor,
        jsonb_build_object('name', v_name, 'job_number', v_job_number)
    );

    RETURN v_job_id;
END;
$$;

-- Backfill job numbers (do not overwrite existing values)
WITH existing AS (
    SELECT
        company_id,
        MAX(
            CASE
                WHEN job_number ~ '^J-[0-9]{2}-[0-9]{4}$'
                    THEN split_part(job_number, '-', 3)::int
                ELSE NULL
            END
        ) AS max_seq
    FROM public.jobs
    WHERE job_number IS NOT NULL
    GROUP BY company_id
),
ordered AS (
    SELECT
        j.id,
        j.company_id,
        ROW_NUMBER() OVER (PARTITION BY j.company_id ORDER BY j.created_at ASC, j.id ASC) AS rn,
        COALESCE(e.max_seq, 0) AS base_seq
    FROM public.jobs j
    LEFT JOIN existing e ON e.company_id = j.company_id
    WHERE j.job_number IS NULL
),
formatted AS (
    SELECT
        id,
        format('J-%s-%s', to_char(now(), 'YY'), lpad((base_seq + rn)::text, 4, '0')) AS job_number
    FROM ordered
)
UPDATE public.jobs j
SET job_number = f.job_number
FROM formatted f
WHERE j.id = f.id;

-- Advance counters based on max sequence per company
WITH seqs AS (
    SELECT
        company_id,
        MAX(
            CASE
                WHEN job_number ~ '^J-[0-9]{2}-[0-9]{4}$'
                    THEN split_part(job_number, '-', 3)::int
                ELSE NULL
            END
        ) AS max_seq
    FROM public.jobs
    WHERE job_number IS NOT NULL
    GROUP BY company_id
)
UPDATE public.company_counters c
SET next_job_number = GREATEST(COALESCE(seqs.max_seq, 0) + 1, c.next_job_number),
    updated_at = now()
FROM seqs
WHERE c.company_id = seqs.company_id;

-- Persist related job numbers on orders/purchase_orders
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS related_job_numbers TEXT[];

ALTER TABLE public.purchase_orders
    ADD COLUMN IF NOT EXISTS related_job_numbers TEXT[];

COMMIT;
