BEGIN;

-- Drop old function signature from 20260109150000_fix_po_lines_table_reference.sql to avoid overload conflicts
DROP FUNCTION IF EXISTS public.add_receipt_line(UUID, UUID, UUID, INTEGER, INTEGER, INTEGER, TEXT);

CREATE OR REPLACE FUNCTION public.add_receipt_line(
    p_receipt_id UUID,
    p_item_id UUID,
    p_received_qty INTEGER,
    p_expected_qty INTEGER DEFAULT NULL,
    p_rejected_qty INTEGER DEFAULT 0,
    p_rejection_reason TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_unit_cost NUMERIC DEFAULT NULL,
    p_lot_number TEXT DEFAULT NULL,
    p_expiration_date DATE DEFAULT NULL,
    p_po_line_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_line_id UUID;
    v_actor UUID := auth.uid();
BEGIN
    IF p_receipt_id IS NULL OR p_item_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    IF p_received_qty IS NULL OR p_received_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid received_qty');
    END IF;
    IF p_rejected_qty IS NULL OR p_rejected_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid rejected_qty');
    END IF;
    IF p_expected_qty IS NOT NULL AND p_expected_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid expected_qty');
    END IF;
    IF p_rejected_qty > 0 AND (p_rejection_reason IS NULL OR length(trim(p_rejection_reason)) = 0) THEN
        RETURN json_build_object('success', false, 'error', 'Rejection reason required');
    END IF;

    SELECT *
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF v_receipt.status NOT IN ('draft','blocked_by_plan') THEN
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

    IF v_receipt.purchase_order_id IS NOT NULL AND p_po_line_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'PO line required for PO receipt');
    END IF;
    IF v_receipt.purchase_order_id IS NULL AND p_po_line_id IS NOT NULL THEN
        RETURN json_build_object('success', false, 'error', 'PO line not allowed for non-PO receipt');
    END IF;
    IF p_po_line_id IS NOT NULL THEN
        IF to_regclass('public.purchase_order_items') IS NOT NULL THEN
            PERFORM 1
            FROM public.purchase_order_items
            WHERE id = p_po_line_id
              AND purchase_order_id = v_receipt.purchase_order_id;
            IF NOT FOUND THEN
                RETURN json_build_object('success', false, 'error', 'PO line not found');
            END IF;
        ELSIF to_regclass('public.purchase_order_lines') IS NOT NULL THEN
            PERFORM 1
            FROM public.purchase_order_lines
            WHERE id = p_po_line_id
              AND purchase_order_id = v_receipt.purchase_order_id;
            IF NOT FOUND THEN
                RETURN json_build_object('success', false, 'error', 'PO line not found');
            END IF;
        ELSE
            RETURN json_build_object('success', false, 'error', 'Purchase order lines not supported');
        END IF;
    END IF;

    INSERT INTO public.receipt_lines (
        receipt_id,
        item_id,
        po_line_id,
        expected_qty,
        received_qty,
        rejected_qty,
        rejection_reason,
        unit_cost,
        lot_number,
        expiration_date,
        notes,
        created_at,
        created_by,
        updated_at,
        updated_by
    ) VALUES (
        p_receipt_id,
        p_item_id,
        p_po_line_id,
        p_expected_qty,
        p_received_qty,
        p_rejected_qty,
        p_rejection_reason,
        p_unit_cost,
        p_lot_number,
        p_expiration_date,
        p_notes,
        now(),
        v_actor,
        now(),
        v_actor
    )
    RETURNING id INTO v_line_id;

    PERFORM public.log_receipt_audit_event(
        'receipt_line_received',
        v_receipt.id,
        v_receipt.purchase_order_id,
        v_receipt.company_id,
        v_actor,
        jsonb_build_object(
            'line_id', v_line_id,
            'item_id', p_item_id,
            'received_qty', p_received_qty,
            'rejected_qty', p_rejected_qty,
            'action', 'inserted'
        )
    );

    RETURN json_build_object('success', true, 'line_id', v_line_id, 'action', 'inserted');
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_receipt_line(UUID, UUID, INTEGER, INTEGER, INTEGER, TEXT, TEXT, NUMERIC, TEXT, DATE, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_receipt_line(
    p_receipt_id UUID,
    p_line_id UUID,
    p_received_qty INTEGER,
    p_expected_qty INTEGER DEFAULT NULL,
    p_rejected_qty INTEGER DEFAULT 0,
    p_rejection_reason TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_unit_cost NUMERIC DEFAULT NULL,
    p_lot_number TEXT DEFAULT NULL,
    p_expiration_date DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_line_id UUID;
    v_item_id UUID;
    v_po_line_id UUID;
    v_actor UUID := auth.uid();
BEGIN
    IF p_receipt_id IS NULL OR p_line_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    IF p_received_qty IS NULL OR p_received_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid received_qty');
    END IF;
    IF p_rejected_qty IS NULL OR p_rejected_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid rejected_qty');
    END IF;
    IF p_expected_qty IS NOT NULL AND p_expected_qty < 0 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid expected_qty');
    END IF;
    IF p_rejected_qty > 0 AND (p_rejection_reason IS NULL OR length(trim(p_rejection_reason)) = 0) THEN
        RETURN json_build_object('success', false, 'error', 'Rejection reason required');
    END IF;

    SELECT *
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF v_receipt.status NOT IN ('draft','blocked_by_plan') THEN
        RETURN json_build_object('success', false, 'error', 'Receipt is not editable');
    END IF;

    IF NOT public.check_permission(v_receipt.company_id, 'receiving:edit') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    SELECT id
        , item_id
        , po_line_id
    INTO v_line_id, v_item_id, v_po_line_id
    FROM public.receipt_lines
    WHERE id = p_line_id
      AND receipt_id = p_receipt_id
    FOR UPDATE;

    IF v_line_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Receipt line not found');
    END IF;

    IF v_receipt.purchase_order_id IS NOT NULL AND v_po_line_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'PO line required for PO receipt');
    END IF;
    IF v_po_line_id IS NOT NULL THEN
        IF to_regclass('public.purchase_order_items') IS NOT NULL THEN
            PERFORM 1
            FROM public.purchase_order_items
            WHERE id = v_po_line_id
              AND purchase_order_id = v_receipt.purchase_order_id;
            IF NOT FOUND THEN
                RETURN json_build_object('success', false, 'error', 'PO line not found');
            END IF;
        ELSIF to_regclass('public.purchase_order_lines') IS NOT NULL THEN
            PERFORM 1
            FROM public.purchase_order_lines
            WHERE id = v_po_line_id
              AND purchase_order_id = v_receipt.purchase_order_id;
            IF NOT FOUND THEN
                RETURN json_build_object('success', false, 'error', 'PO line not found');
            END IF;
        ELSE
            RETURN json_build_object('success', false, 'error', 'Purchase order lines not supported');
        END IF;
    END IF;

    PERFORM 1
    FROM public.inventory_items
    WHERE id = v_item_id
      AND company_id = v_receipt.company_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Item not found');
    END IF;

    UPDATE public.receipt_lines
    SET expected_qty = p_expected_qty,
        received_qty = p_received_qty,
        rejected_qty = p_rejected_qty,
        rejection_reason = p_rejection_reason,
        unit_cost = p_unit_cost,
        lot_number = p_lot_number,
        expiration_date = p_expiration_date,
        notes = p_notes,
        updated_at = now(),
        updated_by = v_actor
    WHERE id = v_line_id;

    PERFORM public.log_receipt_audit_event(
        'receipt_line_received',
        v_receipt.id,
        v_receipt.purchase_order_id,
        v_receipt.company_id,
        v_actor,
        jsonb_build_object(
            'line_id', v_line_id,
            'item_id', v_item_id,
            'received_qty', p_received_qty,
            'rejected_qty', p_rejected_qty,
            'action', 'updated'
        )
    );

    RETURN json_build_object('success', true, 'line_id', v_line_id, 'action', 'updated');
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_receipt_line(UUID, UUID, INTEGER, INTEGER, INTEGER, TEXT, TEXT, NUMERIC, TEXT, DATE) TO authenticated;

COMMIT;
