-- Update approve_job guardrail to block only on fulfillability regression

BEGIN;

DROP FUNCTION IF EXISTS public.approve_job(UUID);

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
    v_is_fulfillable BOOLEAN := true;
    v_was_fulfillable BOOLEAN := COALESCE(p_was_fulfillable, false);
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
        RETURN jsonb_build_object('job_id', p_job_id, 'status', v_status, 'idempotent', true);
    END IF;

    IF v_status NOT IN ('draft', 'quoted') THEN
        RAISE EXCEPTION 'Job cannot be approved from status %', v_status;
    END IF;

    IF NOT public.user_can_delete(v_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    -- Lock inventory items referenced by this job's BOM
    PERFORM 1
    FROM public.inventory_items i
    JOIN public.job_bom b ON b.item_id = i.id
    WHERE b.job_id = p_job_id
    FOR UPDATE;

    WITH bom AS (
        SELECT b.item_id, b.qty_planned
        FROM public.job_bom b
        WHERE b.job_id = p_job_id
    ), reserved AS (
        SELECT b.item_id, SUM(b.qty_planned) AS reserved_qty
        FROM public.job_bom b
        JOIN public.jobs j ON j.id = b.job_id
        WHERE j.status IN ('approved', 'in_progress')
        GROUP BY b.item_id
    ), shortages AS (
        SELECT
            bom.item_id,
            bom.qty_planned,
            i.quantity AS on_hand,
            COALESCE(reserved.reserved_qty, 0) AS reserved_qty,
            (i.quantity - COALESCE(reserved.reserved_qty, 0)) AS available,
            GREATEST(bom.qty_planned - (i.quantity - COALESCE(reserved.reserved_qty, 0)), 0) AS shortfall
        FROM bom
        JOIN public.inventory_items i ON i.id = bom.item_id
        LEFT JOIN reserved ON reserved.item_id = bom.item_id
        WHERE (i.quantity - COALESCE(reserved.reserved_qty, 0)) < bom.qty_planned
    )
    SELECT jsonb_agg(jsonb_build_object(
        'item_id', item_id,
        'required', qty_planned,
        'available', available,
        'shortfall', shortfall
    ))
    INTO v_shortages
    FROM shortages;

    v_is_fulfillable := v_shortages IS NULL;

    IF v_was_fulfillable AND NOT v_is_fulfillable THEN
        RAISE EXCEPTION USING
            MESSAGE = 'Inventory changed during job approval';
    END IF;

    UPDATE public.jobs
    SET status = 'approved',
        updated_at = now()
    WHERE id = p_job_id;

    SELECT jsonb_agg(jsonb_build_object(
        'item_id', b.item_id,
        'qty_planned', b.qty_planned
    ))
    INTO v_reserved_payload
    FROM public.job_bom b
    WHERE b.job_id = p_job_id;

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

GRANT EXECUTE ON FUNCTION public.approve_job(UUID, BOOLEAN) TO authenticated;

COMMIT;
