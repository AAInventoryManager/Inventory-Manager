-- Jobs RPCs: create, BOM, approve, complete, void

BEGIN;

CREATE OR REPLACE FUNCTION public.log_job_event(
    p_event_name TEXT,
    p_job_id UUID,
    p_company_id UUID,
    p_actor_user_id UUID,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.audit_log (
        action,
        table_name,
        record_id,
        company_id,
        user_id,
        new_values
    ) VALUES (
        'INSERT',
        'job_events',
        p_job_id,
        p_company_id,
        p_actor_user_id,
        COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
            'event_name', p_event_name,
            'job_id', p_job_id,
            'company_id', p_company_id,
            'actor_user_id', p_actor_user_id,
            'timestamp', now()
        )
    );
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

    INSERT INTO public.jobs (
        company_id,
        name,
        status,
        notes,
        created_by,
        created_at,
        updated_at
    ) VALUES (
        p_company_id,
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
        jsonb_build_object('name', v_name)
    );

    RETURN v_job_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_job_bom_line(
    p_job_id UUID,
    p_item_id UUID,
    p_qty_planned NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID;
    v_status TEXT;
    v_existing_id UUID;
    v_item_company UUID;
    v_on_hand NUMERIC;
    v_reserved NUMERIC := 0;
    v_available NUMERIC := 0;
    v_shortfall NUMERIC := 0;
BEGIN
    IF p_job_id IS NULL THEN
        RAISE EXCEPTION 'Missing job_id';
    END IF;

    IF p_item_id IS NULL THEN
        RAISE EXCEPTION 'Missing item_id';
    END IF;

    IF p_qty_planned IS NULL OR p_qty_planned <= 0 THEN
        RAISE EXCEPTION 'qty_planned must be greater than zero';
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

    IF v_status NOT IN ('draft', 'quoted') THEN
        RAISE EXCEPTION 'BOM updates allowed only in draft or quoted';
    END IF;

    IF NOT public.user_can_write(v_company_id) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT company_id, quantity
    INTO v_item_company, v_on_hand
    FROM public.inventory_items
    WHERE id = p_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item not found';
    END IF;

    IF v_item_company <> v_company_id THEN
        RAISE EXCEPTION 'Item does not belong to company';
    END IF;

    SELECT id
    INTO v_existing_id
    FROM public.job_bom
    WHERE job_id = p_job_id
      AND item_id = p_item_id;

    IF FOUND THEN
        UPDATE public.job_bom
        SET qty_planned = p_qty_planned
        WHERE id = v_existing_id;
    ELSE
        INSERT INTO public.job_bom (job_id, item_id, qty_planned, created_at)
        VALUES (p_job_id, p_item_id, p_qty_planned, now());
    END IF;

    UPDATE public.jobs
    SET updated_at = now()
    WHERE id = p_job_id;

    SELECT COALESCE(SUM(b.qty_planned), 0)
    INTO v_reserved
    FROM public.job_bom b
    JOIN public.jobs j ON j.id = b.job_id
    WHERE b.item_id = p_item_id
      AND j.status IN ('approved', 'in_progress');

    v_available := COALESCE(v_on_hand, 0) - COALESCE(v_reserved, 0);
    v_shortfall := GREATEST(p_qty_planned - v_available, 0);

    RETURN jsonb_build_object(
        'job_id', p_job_id,
        'item_id', p_item_id,
        'qty_planned', p_qty_planned,
        'available', v_available,
        'shortfall', v_shortfall
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_job(p_job_id UUID)
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

    IF v_shortages IS NOT NULL THEN
        RAISE EXCEPTION 'Insufficient inventory: %', v_shortages::text;
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

    PERFORM public.log_job_event('job_voided', p_job_id, v_company_id, v_actor, NULL);

    RETURN jsonb_build_object('job_id', p_job_id, 'status', 'voided');
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_job_event(TEXT, UUID, UUID, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_job(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_job_bom_line(UUID, UUID, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_job(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_job(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_job(UUID) TO authenticated;

COMMIT;
