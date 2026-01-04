-- Align receipt completion metrics with action_metrics schema (no quantity_delta)

BEGIN;

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

    SELECT effective_tier INTO v_tier FROM public.get_company_tier(v_receipt.company_id);
    IF v_tier = 'starter' THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF v_receipt.status = v_next THEN
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
        IF v_receipt.status = 'draft' AND v_tier = 'professional' THEN
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
