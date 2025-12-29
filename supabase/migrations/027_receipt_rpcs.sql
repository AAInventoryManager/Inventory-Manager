-- Receipt-based receiving RPCs (Inventory Receiving v2)

BEGIN;

-- Helper: audit receipt lifecycle events
CREATE OR REPLACE FUNCTION public.log_receipt_audit_event(
    p_event_name TEXT,
    p_receipt_id UUID,
    p_purchase_order_id UUID,
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
        'receipt_events',
        p_receipt_id,
        p_company_id,
        p_actor_user_id,
        COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
            'event_name', p_event_name,
            'receipt_id', p_receipt_id,
            'purchase_order_id', p_purchase_order_id,
            'company_id', p_company_id,
            'actor_user_id', p_actor_user_id,
            'timestamp', now()
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_receipt(
    p_company_id UUID,
    p_purchase_order_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt_id UUID;
    v_actor UUID := auth.uid();
BEGIN
    IF p_company_id IS NULL OR p_purchase_order_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    IF NOT public.check_permission(p_company_id, 'receiving:create') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    INSERT INTO public.receipts (
        company_id,
        purchase_order_id,
        status,
        received_by
    ) VALUES (
        p_company_id,
        p_purchase_order_id,
        'draft',
        v_actor
    )
    RETURNING id INTO v_receipt_id;

    PERFORM public.log_receipt_audit_event(
        'receipt_created',
        v_receipt_id,
        p_purchase_order_id,
        p_company_id,
        v_actor
    );

    RETURN json_build_object('success', true, 'receipt_id', v_receipt_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_receipt(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.upsert_receipt_line(
    p_receipt_id UUID,
    p_item_id UUID,
    p_qty_received NUMERIC,
    p_qty_rejected NUMERIC DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_line_id UUID;
    v_action TEXT := 'inserted';
    v_actor UUID := auth.uid();
BEGIN
    IF p_receipt_id IS NULL OR p_item_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    IF p_qty_received IS NULL OR p_qty_rejected IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing quantities');
    END IF;

    IF p_qty_received < 0 OR p_qty_rejected < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid quantities');
    END IF;

    SELECT *
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF v_receipt.status <> 'draft' THEN
        RETURN json_build_object('success', false, 'error', 'Receipt is not editable');
    END IF;

    IF NOT public.check_permission(v_receipt.company_id, 'receiving:edit') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    PERFORM 1
    FROM public.inventory_items
    WHERE id = p_item_id
      AND company_id = v_receipt.company_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Item not found');
    END IF;

    SELECT id
    INTO v_line_id
    FROM public.receipt_lines
    WHERE receipt_id = p_receipt_id
      AND item_id = p_item_id
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_line_id IS NULL THEN
        INSERT INTO public.receipt_lines (
            receipt_id,
            item_id,
            qty_received,
            qty_rejected
        ) VALUES (
            p_receipt_id,
            p_item_id,
            p_qty_received,
            p_qty_rejected
        )
        RETURNING id INTO v_line_id;
    ELSE
        UPDATE public.receipt_lines
        SET qty_received = p_qty_received,
            qty_rejected = p_qty_rejected
        WHERE id = v_line_id;

        v_action := 'updated';
    END IF;

    PERFORM public.log_receipt_audit_event(
        'receipt_line_received',
        v_receipt.id,
        v_receipt.purchase_order_id,
        v_receipt.company_id,
        v_actor,
        jsonb_build_object(
            'line_id', v_line_id,
            'item_id', p_item_id,
            'qty_received', p_qty_received,
            'qty_rejected', p_qty_rejected,
            'action', v_action
        )
    );

    RETURN json_build_object('success', true, 'line_id', v_line_id, 'action', v_action);
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_receipt_line(UUID, UUID, NUMERIC, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION public.complete_receipt(p_receipt_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_line_count INTEGER := 0;
    v_actor UUID := auth.uid();
BEGIN
    IF p_receipt_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing receipt_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT *
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF NOT public.check_permission(v_receipt.company_id, 'receiving:approve') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_receipt.status = 'completed' THEN
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'already_completed', true);
    END IF;

    IF v_receipt.status <> 'draft' THEN
        RETURN json_build_object('success', false, 'error', 'Receipt cannot be completed');
    END IF;

    SELECT COUNT(*)
    INTO v_line_count
    FROM public.receipt_lines
    WHERE receipt_id = p_receipt_id;

    IF v_line_count = 0 THEN
        RETURN json_build_object('success', false, 'error', 'Receipt has no lines');
    END IF;

    UPDATE public.inventory_items i
    SET quantity = i.quantity + rl.qty_received
    FROM public.receipt_lines rl
    WHERE rl.receipt_id = p_receipt_id
      AND rl.item_id = i.id
      AND i.company_id = v_receipt.company_id;

    UPDATE public.receipts
    SET status = 'completed',
        received_at = now()
    WHERE id = p_receipt_id
      AND status = 'draft';

    PERFORM public.log_receipt_audit_event(
        'receipt_completed',
        v_receipt.id,
        v_receipt.purchase_order_id,
        v_receipt.company_id,
        v_actor,
        jsonb_build_object('lines_count', v_line_count)
    );

    RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'lines_applied', v_line_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_receipt(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.void_receipt(p_receipt_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_line_count INTEGER := 0;
    v_actor UUID := auth.uid();
BEGIN
    IF p_receipt_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing receipt_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT *
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF NOT public.check_permission(v_receipt.company_id, 'receiving:void') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_receipt.status = 'voided' THEN
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'already_voided', true);
    END IF;

    IF v_receipt.status <> 'completed' THEN
        RETURN json_build_object('success', false, 'error', 'Receipt cannot be voided');
    END IF;

    SELECT COUNT(*)
    INTO v_line_count
    FROM public.receipt_lines
    WHERE receipt_id = p_receipt_id;

    UPDATE public.inventory_items i
    SET quantity = i.quantity - rl.qty_received
    FROM public.receipt_lines rl
    WHERE rl.receipt_id = p_receipt_id
      AND rl.item_id = i.id
      AND i.company_id = v_receipt.company_id;

    UPDATE public.receipts
    SET status = 'voided'
    WHERE id = p_receipt_id
      AND status = 'completed';

    PERFORM public.log_receipt_audit_event(
        'receipt_voided',
        v_receipt.id,
        v_receipt.purchase_order_id,
        v_receipt.company_id,
        v_actor,
        jsonb_build_object('lines_count', v_line_count)
    );

    RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'lines_reversed', v_line_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.void_receipt(UUID) TO authenticated;

COMMIT;
