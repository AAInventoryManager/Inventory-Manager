-- Allow unplanned items during job completion
-- Instead of rejecting items not in BOM, auto-add them as BOM lines

BEGIN;

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
    v_shortages JSONB;
    v_consumed_payload JSONB;
    v_added_items UUID[];
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

    -- Check that all BOM items have actuals (can be zero)
    SELECT array_agg(b.item_id)
    INTO v_missing
    FROM public.job_bom b
    WHERE b.job_id = p_job_id
      AND b.item_id NOT IN (SELECT item_id FROM job_actuals_input);

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing actuals for items: %', array_to_string(v_missing, ',');
    END IF;

    -- Auto-add BOM lines for unplanned items (items in actuals but not in BOM)
    -- This allows adding items during job execution that weren't originally planned
    INSERT INTO public.job_bom (job_id, item_id, qty_planned, created_at)
    SELECT p_job_id, a.item_id, a.qty_used, now()
    FROM job_actuals_input a
    WHERE a.item_id NOT IN (SELECT item_id FROM public.job_bom WHERE job_id = p_job_id)
      AND a.qty_used > 0
    RETURNING item_id INTO v_added_items;

    -- Verify all items belong to the same company
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

    -- Check for insufficient inventory
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

    -- Consume inventory
    UPDATE public.inventory_items i
    SET quantity = i.quantity - a.qty_used,
        updated_at = now()
    FROM job_actuals_input a
    WHERE i.id = a.item_id;

    -- Record actuals
    DELETE FROM public.job_actuals
    WHERE job_id = p_job_id;

    INSERT INTO public.job_actuals (job_id, item_id, qty_used, created_at)
    SELECT p_job_id, item_id, qty_used, now()
    FROM job_actuals_input;

    -- Mark job completed
    UPDATE public.jobs
    SET status = 'completed',
        updated_at = now()
    WHERE id = p_job_id;

    -- Build consumed payload for logging
    SELECT jsonb_agg(jsonb_build_object(
        'item_id', item_id,
        'qty_used', qty_used
    ))
    INTO v_consumed_payload
    FROM job_actuals_input;

    -- Log events
    PERFORM public.log_job_event('job_completed', p_job_id, v_company_id, v_actor, NULL);
    PERFORM public.log_job_event(
        'job_inventory_consumed',
        p_job_id,
        v_company_id,
        v_actor,
        jsonb_build_object('items', COALESCE(v_consumed_payload, '[]'::jsonb))
    );

    RETURN jsonb_build_object(
        'job_id', p_job_id,
        'status', 'completed',
        'unplanned_items_added', COALESCE(array_length(v_added_items, 1), 0)
    );
END;
$$;

COMMIT;
