-- Deterministic shortfalls for job allocation gaps

BEGIN;

CREATE TABLE IF NOT EXISTS public.shortfalls (
    shortfall_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    qty_missing INTEGER NOT NULL CHECK (qty_missing > 0),
    status TEXT NOT NULL CHECK (status IN ('active', 'resolved', 'canceled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES auth.users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID NOT NULL REFERENCES auth.users(id)
);

COMMENT ON TABLE public.shortfalls IS
    'Deterministic job shortfalls for allocation gaps. One active shortfall per job and item.';

CREATE INDEX IF NOT EXISTS idx_shortfalls_company_id
    ON public.shortfalls(company_id);

CREATE INDEX IF NOT EXISTS idx_shortfalls_job_id
    ON public.shortfalls(job_id);

CREATE INDEX IF NOT EXISTS idx_shortfalls_item_id
    ON public.shortfalls(item_id);

CREATE INDEX IF NOT EXISTS idx_shortfalls_status
    ON public.shortfalls(status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_shortfalls_active_job_item
    ON public.shortfalls(job_id, item_id)
    WHERE status = 'active';

ALTER TABLE public.shortfalls ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view shortfalls" ON public.shortfalls;
CREATE POLICY "Users can view shortfalls"
    ON public.shortfalls FOR SELECT
    USING (company_id IN (SELECT public.get_user_company_ids()));

CREATE OR REPLACE FUNCTION public.approve_job(
    p_job_id UUID,
    p_was_fulfillable BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID;
    v_status TEXT;
    v_shortages JSONB;
    v_reserved_payload JSONB;
    v_was_fulfillable BOOLEAN := COALESCE(p_was_fulfillable, false);
    v_block_reason TEXT := 'insufficient_inventory';
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'Missing job_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT company_id, status
    INTO v_company_id, v_status
    FROM public.jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Job not found';
    END IF;

    IF v_status = 'approved' THEN
        UPDATE public.shortfalls
        SET status = 'resolved',
            updated_at = now(),
            updated_by = v_actor
        WHERE job_id = p_job_id
          AND status = 'active';

        RETURN jsonb_build_object('job_id', p_job_id, 'status', v_status, 'idempotent', true);
    END IF;

    IF v_status NOT IN ('draft', 'quoted') THEN
        RAISE EXCEPTION 'Job cannot be approved from status %', v_status;
    END IF;

    IF NOT public.user_can_delete(v_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.job_bom b
        WHERE b.job_id = p_job_id
          AND b.qty_planned <> floor(b.qty_planned)
    ) THEN
        RAISE EXCEPTION 'Planned quantities must be whole numbers for allocation';
    END IF;

    -- Lock inventory items referenced by this job's BOM
    PERFORM 1
    FROM public.inventory_items i
    JOIN public.job_bom b ON b.item_id = i.id
    WHERE b.job_id = p_job_id
    FOR UPDATE;

    CREATE TEMP TABLE job_shortages (
        item_id UUID,
        qty_planned INTEGER,
        on_hand INTEGER,
        allocated_qty INTEGER,
        available INTEGER,
        shortfall INTEGER
    ) ON COMMIT DROP;

    INSERT INTO job_shortages (item_id, qty_planned, on_hand, allocated_qty, available, shortfall)
    WITH bom AS (
        SELECT b.item_id, SUM(b.qty_planned)::integer AS qty_planned
        FROM public.job_bom b
        WHERE b.job_id = p_job_id
        GROUP BY b.item_id
    ), allocated AS (
        SELECT a.item_id, SUM(a.qty_allocated)::integer AS allocated_qty
        FROM public.allocations a
        WHERE a.job_id <> p_job_id
        GROUP BY a.item_id
    )
    SELECT
        bom.item_id,
        bom.qty_planned,
        i.quantity::integer AS on_hand,
        COALESCE(allocated.allocated_qty, 0)::integer AS allocated_qty,
        (i.quantity - COALESCE(allocated.allocated_qty, 0))::integer AS available,
        GREATEST(bom.qty_planned - (i.quantity - COALESCE(allocated.allocated_qty, 0)), 0)::integer AS shortfall
    FROM bom
    JOIN public.inventory_items i ON i.id = bom.item_id
    LEFT JOIN allocated ON allocated.item_id = bom.item_id
    WHERE (i.quantity - COALESCE(allocated.allocated_qty, 0)) < bom.qty_planned;

    SELECT jsonb_agg(jsonb_build_object(
        'item_id', item_id,
        'required', qty_planned,
        'available', available,
        'shortfall', shortfall
    ))
    INTO v_shortages
    FROM job_shortages;

    IF v_shortages IS NOT NULL THEN
        IF v_was_fulfillable THEN
            v_block_reason := 'inventory_changed';
        END IF;

        INSERT INTO public.shortfalls (
            company_id,
            job_id,
            item_id,
            qty_missing,
            status,
            created_at,
            created_by,
            updated_at,
            updated_by
        )
        SELECT
            v_company_id,
            p_job_id,
            item_id,
            shortfall,
            'active',
            now(),
            v_actor,
            now(),
            v_actor
        FROM job_shortages
        ON CONFLICT (job_id, item_id) WHERE status = 'active'
        DO UPDATE SET
            qty_missing = EXCLUDED.qty_missing,
            updated_at = now(),
            updated_by = v_actor;

        UPDATE public.shortfalls
        SET status = 'resolved',
            updated_at = now(),
            updated_by = v_actor
        WHERE job_id = p_job_id
          AND status = 'active'
          AND item_id NOT IN (SELECT item_id FROM job_shortages);

        RETURN jsonb_build_object(
            'job_id', p_job_id,
            'status', v_status,
            'blocked', true,
            'reason', v_block_reason,
            'shortfalls', v_shortages
        );
    END IF;

    UPDATE public.jobs
    SET status = 'approved',
        updated_at = now()
    WHERE id = p_job_id;

    WITH bom AS (
        SELECT b.item_id, SUM(b.qty_planned) AS qty_planned
        FROM public.job_bom b
        WHERE b.job_id = p_job_id
        GROUP BY b.item_id
    )
    INSERT INTO public.allocations (
        company_id,
        job_id,
        item_id,
        qty_allocated,
        created_at,
        created_by,
        updated_at,
        updated_by
    )
    SELECT
        v_company_id,
        p_job_id,
        bom.item_id,
        bom.qty_planned::integer,
        now(),
        v_actor,
        now(),
        v_actor
    FROM bom
    ON CONFLICT (job_id, item_id)
    DO UPDATE SET
        qty_allocated = EXCLUDED.qty_allocated,
        updated_at = now(),
        updated_by = v_actor;

    UPDATE public.shortfalls
    SET status = 'resolved',
        updated_at = now(),
        updated_by = v_actor
    WHERE job_id = p_job_id
      AND status = 'active';

    SELECT jsonb_agg(jsonb_build_object(
        'item_id', b.item_id,
        'qty_planned', b.qty_planned
    ))
    INTO v_reserved_payload
    FROM (
        SELECT item_id, SUM(qty_planned) AS qty_planned
        FROM public.job_bom
        WHERE job_id = p_job_id
        GROUP BY item_id
    ) b;

    PERFORM public.log_job_event('job_approved', p_job_id, v_company_id, v_actor, NULL);
    PERFORM public.log_job_event(
        'job_inventory_reserved',
        p_job_id,
        v_company_id,
        v_actor,
        jsonb_build_object('items', COALESCE(v_reserved_payload, '[]'::jsonb))
    );

    RETURN jsonb_build_object('job_id', p_job_id, 'status', 'approved');
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_job(
    p_job_id UUID,
    p_actuals JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID;
    v_status TEXT;
    v_missing UUID[];
    v_extra UUID[];
    v_shortages JSONB;
    v_consumed_payload JSONB;
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'Missing job_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT company_id, status
    INTO v_company_id, v_status
    FROM public.jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Job not found';
    END IF;

    IF v_status = 'completed' THEN
        RETURN jsonb_build_object('job_id', p_job_id, 'status', v_status, 'idempotent', true);
    END IF;

    IF v_status NOT IN ('approved', 'in_progress') THEN
        RAISE EXCEPTION 'Job cannot be completed from status %', v_status;
    END IF;

    IF NOT public.user_can_delete(v_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_actuals IS NULL OR jsonb_typeof(p_actuals) <> 'array' THEN
        RAISE EXCEPTION 'Actuals payload required';
    END IF;

    CREATE TEMP TABLE job_actuals_input (
        item_id UUID,
        qty_used NUMERIC
    ) ON COMMIT DROP;

    INSERT INTO job_actuals_input (item_id, qty_used)
    SELECT
        nullif(value->>'item_id', '')::uuid,
        (value->>'qty_used')::numeric
    FROM jsonb_array_elements(p_actuals) AS value;

    IF EXISTS (SELECT 1 FROM job_actuals_input WHERE item_id IS NULL) THEN
        RAISE EXCEPTION 'Actuals item_id is required';
    END IF;

    IF EXISTS (SELECT 1 FROM job_actuals_input WHERE qty_used IS NULL OR qty_used < 0) THEN
        RAISE EXCEPTION 'Actuals qty_used must be >= 0';
    END IF;

    IF (SELECT COUNT(*) FROM job_actuals_input) = 0 THEN
        RAISE EXCEPTION 'Actuals payload required';
    END IF;

    IF (SELECT COUNT(*) FROM (SELECT DISTINCT item_id FROM job_actuals_input) AS d)
        <> (SELECT COUNT(*) FROM job_actuals_input) THEN
        RAISE EXCEPTION 'Duplicate actuals lines';
    END IF;

    SELECT array_agg(b.item_id)
    INTO v_missing
    FROM public.job_bom b
    WHERE b.job_id = p_job_id
      AND b.item_id NOT IN (SELECT item_id FROM job_actuals_input);

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing actuals for items: %', array_to_string(v_missing, ',');
    END IF;

    SELECT array_agg(a.item_id)
    INTO v_extra
    FROM job_actuals_input a
    WHERE a.item_id NOT IN (SELECT item_id FROM public.job_bom WHERE job_id = p_job_id);

    IF v_extra IS NOT NULL THEN
        RAISE EXCEPTION 'Unexpected actuals for items: %', array_to_string(v_extra, ',');
    END IF;

    IF EXISTS (
        SELECT 1
        FROM job_actuals_input a
        JOIN public.inventory_items i ON i.id = a.item_id
        WHERE i.company_id <> v_company_id
    ) THEN
        RAISE EXCEPTION 'Actuals item not in company';
    END IF;

    -- Lock inventory rows for actuals
    PERFORM 1
    FROM public.inventory_items i
    JOIN job_actuals_input a ON a.item_id = i.id
    FOR UPDATE;

    WITH insufficient AS (
        SELECT
            a.item_id,
            a.qty_used,
            i.quantity AS on_hand
        FROM job_actuals_input a
        JOIN public.inventory_items i ON i.id = a.item_id
        WHERE i.quantity < a.qty_used
    )
    SELECT jsonb_agg(jsonb_build_object(
        'item_id', item_id,
        'required', qty_used,
        'on_hand', on_hand,
        'shortfall', (qty_used - on_hand)
    ))
    INTO v_shortages
    FROM insufficient;

    IF v_shortages IS NOT NULL THEN
        RAISE EXCEPTION 'Insufficient inventory for actuals: %', v_shortages::text;
    END IF;

    UPDATE public.inventory_items i
    SET quantity = i.quantity - a.qty_used,
        updated_at = now()
    FROM job_actuals_input a
    WHERE i.id = a.item_id;

    DELETE FROM public.job_actuals
    WHERE job_id = p_job_id;

    INSERT INTO public.job_actuals (job_id, item_id, qty_used, created_at)
    SELECT p_job_id, item_id, qty_used, now()
    FROM job_actuals_input;

    UPDATE public.jobs
    SET status = 'completed',
        updated_at = now()
    WHERE id = p_job_id;

    DELETE FROM public.allocations
    WHERE job_id = p_job_id;

    UPDATE public.shortfalls
    SET status = 'resolved',
        updated_at = now(),
        updated_by = v_actor
    WHERE job_id = p_job_id
      AND status = 'active';

    SELECT jsonb_agg(jsonb_build_object(
        'item_id', item_id,
        'qty_used', qty_used
    ))
    INTO v_consumed_payload
    FROM job_actuals_input;

    PERFORM public.log_job_event('job_completed', p_job_id, v_company_id, v_actor, NULL);
    PERFORM public.log_job_event(
        'job_inventory_consumed',
        p_job_id,
        v_company_id,
        v_actor,
        jsonb_build_object('items', COALESCE(v_consumed_payload, '[]'::jsonb))
    );

    RETURN jsonb_build_object('job_id', p_job_id, 'status', 'completed');
END;
$$;

CREATE OR REPLACE FUNCTION public.void_job(p_job_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID;
    v_status TEXT;
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'Missing job_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT company_id, status
    INTO v_company_id, v_status
    FROM public.jobs
    WHERE id = p_job_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Job not found';
    END IF;

    IF v_status = 'voided' THEN
        RETURN jsonb_build_object('job_id', p_job_id, 'status', v_status, 'idempotent', true);
    END IF;

    IF v_status = 'completed' THEN
        RAISE EXCEPTION 'Completed jobs cannot be voided';
    END IF;

    IF v_status NOT IN ('draft', 'quoted', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'Job cannot be voided from status %', v_status;
    END IF;

    IF NOT public.user_can_delete(v_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_status IN ('approved', 'in_progress') THEN
        -- Reverse any actuals if they exist
        UPDATE public.inventory_items i
        SET quantity = i.quantity + a.qty_used,
            updated_at = now()
        FROM public.job_actuals a
        WHERE a.job_id = p_job_id
          AND i.id = a.item_id;
    END IF;

    UPDATE public.jobs
    SET status = 'voided',
        updated_at = now()
    WHERE id = p_job_id;

    DELETE FROM public.allocations
    WHERE job_id = p_job_id;

    UPDATE public.shortfalls
    SET status = 'canceled',
        updated_at = now(),
        updated_by = v_actor
    WHERE job_id = p_job_id
      AND status = 'active';

    PERFORM public.log_job_event('job_voided', p_job_id, v_company_id, v_actor, NULL);

    RETURN jsonb_build_object('job_id', p_job_id, 'status', 'voided');
END;
$$;

COMMIT;
