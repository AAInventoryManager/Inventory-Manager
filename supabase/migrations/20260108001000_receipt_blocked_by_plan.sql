-- Allow blocked_by_plan receipt status for inbound receipt ingestion gating.

BEGIN;

ALTER TABLE public.receipts DROP CONSTRAINT IF EXISTS receipts_status_check;
ALTER TABLE public.receipts
  ADD CONSTRAINT receipts_status_check
  CHECK (status IN ('draft','pending','completed','voided','blocked_by_plan')) NOT VALID;
ALTER TABLE public.receipts VALIDATE CONSTRAINT receipts_status_check;

CREATE OR REPLACE FUNCTION public.validate_receipt_transition(
    p_current_status TEXT,
    p_next_status TEXT,
    p_tier TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tier TEXT := lower(trim(COALESCE(p_tier, '')));
    v_current TEXT := lower(trim(COALESCE(p_current_status, '')));
    v_next TEXT := lower(trim(COALESCE(p_next_status, '')));
    v_current_norm TEXT := CASE WHEN v_current = 'blocked_by_plan' THEN 'draft' ELSE v_current END;
BEGIN
    RETURN CASE
        WHEN v_current_norm = 'draft' AND v_next = 'pending'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN v_current_norm = 'draft' AND v_next = 'completed'
            AND v_tier = 'professional' THEN true
        WHEN v_current_norm = 'pending' AND v_next = 'completed'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN v_current_norm = 'pending' AND v_next = 'draft'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN v_current_norm = 'completed' AND v_next = 'voided'
            AND v_tier = 'enterprise' THEN true
        ELSE false
    END;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_receipt_line_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM public.receipts WHERE id = COALESCE(NEW.receipt_id, OLD.receipt_id);
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Receipt not found';
    END IF;

    IF v_status NOT IN ('draft','blocked_by_plan') THEN
        RAISE EXCEPTION 'Receipt lines are editable only in draft';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id THEN
            RAISE EXCEPTION 'receipt_id is write-once';
        END IF;
        IF NEW.item_id IS DISTINCT FROM OLD.item_id THEN
            RAISE EXCEPTION 'item_id is write-once';
        END IF;
        IF NEW.po_line_id IS DISTINCT FROM OLD.po_line_id THEN
            RAISE EXCEPTION 'po_line_id is write-once';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

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
        IF to_regclass('public.purchase_order_lines') IS NULL THEN
            RETURN json_build_object('success', false, 'error', 'Purchase order lines not supported');
        END IF;
        PERFORM 1
        FROM public.purchase_order_lines
        WHERE id = p_po_line_id
          AND purchase_order_id = v_receipt.purchase_order_id;
        IF NOT FOUND THEN
            RETURN json_build_object('success', false, 'error', 'PO line not found');
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
    IF v_po_line_id IS NOT NULL AND to_regclass('public.purchase_order_lines') IS NOT NULL THEN
        PERFORM 1
        FROM public.purchase_order_lines
        WHERE id = v_po_line_id
          AND purchase_order_id = v_receipt.purchase_order_id;
        IF NOT FOUND THEN
            RETURN json_build_object('success', false, 'error', 'PO line not found');
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

CREATE OR REPLACE FUNCTION public.transition_receipt_status(
    p_receipt_id UUID,
    p_next_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt public.receipts%ROWTYPE;
    v_actor UUID := auth.uid();
    v_tier TEXT;
    v_line_count INTEGER := 0;
    v_total_received INTEGER := 0;
    v_valid_item_count INTEGER := 0;
    v_status TEXT;
    v_next TEXT := lower(trim(COALESCE(p_next_status, '')));
BEGIN
    IF p_receipt_id IS NULL OR v_next = '' THEN
        RETURN json_build_object('success', false, 'error', 'Missing required fields');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT * INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    v_status := lower(trim(COALESCE(v_receipt.status, '')));
    SELECT effective_tier INTO v_tier FROM public.get_company_tier(v_receipt.company_id);
    IF v_tier = 'starter' THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF v_status = v_next THEN
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'status', v_receipt.status, 'already_in_state', true);
    END IF;

    IF NOT public.validate_receipt_transition(v_receipt.status, v_next, v_tier) THEN
        RETURN json_build_object('success', false, 'error', 'Invalid receipt status transition');
    END IF;

    IF v_next = 'pending' THEN
        IF NOT public.check_permission(v_receipt.company_id, 'receiving:edit') THEN
            RETURN json_build_object('success', false, 'error', 'Permission denied');
        END IF;
        SELECT COUNT(*) INTO v_line_count FROM public.receipt_lines WHERE receipt_id = p_receipt_id;
        IF v_line_count = 0 THEN
            RETURN json_build_object('success', false, 'error', 'Receipt has no lines');
        END IF;
        UPDATE public.receipts
        SET status = 'pending',
            submitted_at = now(),
            submitted_by = v_actor,
            updated_at = now(),
            updated_by = v_actor
        WHERE id = p_receipt_id;
        PERFORM public.log_receipt_audit_event(
            'receipt_submitted',
            v_receipt.id,
            v_receipt.purchase_order_id,
            v_receipt.company_id,
            v_actor
        );
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'status', 'pending');
    END IF;

    IF v_next = 'draft' THEN
        IF NOT public.check_permission(v_receipt.company_id, 'receiving:approve') THEN
            RETURN json_build_object('success', false, 'error', 'Permission denied');
        END IF;
        UPDATE public.receipts
        SET status = 'draft',
            rejected_at = now(),
            rejected_by = v_actor,
            rejection_reason = p_reason,
            updated_at = now(),
            updated_by = v_actor
        WHERE id = p_receipt_id;
        PERFORM public.log_receipt_audit_event(
            'receipt_rejected',
            v_receipt.id,
            v_receipt.purchase_order_id,
            v_receipt.company_id,
            v_actor
        );
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'status', 'draft');
    END IF;

    IF v_next = 'completed' THEN
        IF (v_status = 'draft' OR v_status = 'blocked_by_plan') AND v_tier = 'professional' THEN
            IF NOT public.check_permission(v_receipt.company_id, 'receiving:edit') THEN
                RETURN json_build_object('success', false, 'error', 'Permission denied');
            END IF;
        ELSE
            IF NOT public.check_permission(v_receipt.company_id, 'receiving:approve') THEN
                RETURN json_build_object('success', false, 'error', 'Permission denied');
            END IF;
        END IF;
        SELECT COUNT(*), COALESCE(SUM(received_qty), 0)
        INTO v_line_count, v_total_received
        FROM public.receipt_lines
        WHERE receipt_id = p_receipt_id;
        IF v_line_count = 0 THEN
            RETURN json_build_object('success', false, 'error', 'Receipt has no lines');
        END IF;
        SELECT COUNT(*)
        INTO v_valid_item_count
        FROM public.receipt_lines rl
        JOIN public.inventory_items i ON i.id = rl.item_id
        WHERE rl.receipt_id = p_receipt_id
          AND i.company_id = v_receipt.company_id
          AND i.deleted_at IS NULL;
        IF v_valid_item_count <> v_line_count THEN
            RETURN json_build_object('success', false, 'error', 'Receipt contains invalid or deleted items');
        END IF;
        UPDATE public.inventory_items i
        SET quantity = i.quantity + rl.received_qty
        FROM public.receipt_lines rl
        WHERE rl.receipt_id = p_receipt_id
          AND rl.item_id = i.id
          AND i.company_id = v_receipt.company_id
          AND i.deleted_at IS NULL;

        UPDATE public.receipts
        SET status = 'completed',
            received_at = now(),
            received_by = v_actor,
            updated_at = now(),
            updated_by = v_actor
        WHERE id = p_receipt_id;

        PERFORM public.log_receipt_audit_event(
            'receipt_completed',
            v_receipt.id,
            v_receipt.purchase_order_id,
            v_receipt.company_id,
            v_actor,
            jsonb_build_object(
                'lines_applied', v_line_count,
                'total_received_qty', v_total_received
            )
        );

        IF to_regclass('public.action_metrics') IS NOT NULL THEN
            INSERT INTO public.action_metrics (
                company_id,
                user_id,
                metric_date,
                action_type,
                table_name,
                quantity_added,
                quantity_removed
            ) VALUES (
                v_receipt.company_id,
                v_actor,
                CURRENT_DATE,
                'update',
                'inventory_items',
                v_total_received,
                0
            )
            ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
            DO UPDATE SET
                quantity_added = action_metrics.quantity_added + EXCLUDED.quantity_added;
        END IF;
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'status', 'completed', 'lines_applied', v_line_count);
    END IF;

    IF v_next = 'voided' THEN
        IF NOT public.check_permission(v_receipt.company_id, 'receiving:void') THEN
            RETURN json_build_object('success', false, 'error', 'Permission denied');
        END IF;
        IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
            RETURN json_build_object('success', false, 'error', 'Void reason required');
        END IF;
        UPDATE public.receipts
        SET status = 'voided',
            voided_at = now(),
            voided_by = v_actor,
            void_reason = p_reason,
            updated_at = now(),
            updated_by = v_actor
        WHERE id = p_receipt_id;
        PERFORM public.log_receipt_audit_event(
            'receipt_voided',
            v_receipt.id,
            v_receipt.purchase_order_id,
            v_receipt.company_id,
            v_actor
        );
        RETURN json_build_object('success', true, 'receipt_id', v_receipt.id, 'status', 'voided');
    END IF;

    RETURN json_build_object('success', false, 'error', 'Unsupported status');
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
