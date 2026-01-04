-- Fix tier resolution in receiving governance functions (use effective_tier)

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_receipt_write_once()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tier TEXT;
BEGIN
    IF (TG_OP = 'UPDATE') THEN
        IF OLD.company_id IS DISTINCT FROM NEW.company_id THEN
            RAISE EXCEPTION 'company_id is immutable';
        END IF;
        IF OLD.receipt_number IS DISTINCT FROM NEW.receipt_number THEN
            RAISE EXCEPTION 'receipt_number is immutable';
        END IF;
        IF NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id THEN
            IF OLD.status <> 'draft' THEN
                RAISE EXCEPTION 'purchase_order_id is immutable once submitted';
            END IF;
        END IF;
        IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'created_at is write-once';
        END IF;
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            RAISE EXCEPTION 'created_by is write-once';
        END IF;
        IF NEW.submitted_by IS DISTINCT FROM OLD.submitted_by AND OLD.submitted_by IS NOT NULL THEN
            RAISE EXCEPTION 'submitted_by is write-once';
        END IF;
        IF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at AND OLD.submitted_at IS NOT NULL THEN
            RAISE EXCEPTION 'submitted_at is write-once';
        END IF;
        IF NEW.received_by IS DISTINCT FROM OLD.received_by AND OLD.received_by IS NOT NULL THEN
            RAISE EXCEPTION 'received_by is write-once';
        END IF;
        IF NEW.received_at IS DISTINCT FROM OLD.received_at AND OLD.received_at IS NOT NULL THEN
            RAISE EXCEPTION 'received_at is write-once';
        END IF;
        IF NEW.voided_by IS DISTINCT FROM OLD.voided_by AND OLD.voided_by IS NOT NULL THEN
            RAISE EXCEPTION 'voided_by is write-once';
        END IF;
        IF NEW.voided_at IS DISTINCT FROM OLD.voided_at AND OLD.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'voided_at is write-once';
        END IF;
        IF NEW.void_reason IS DISTINCT FROM OLD.void_reason AND OLD.void_reason IS NOT NULL THEN
            RAISE EXCEPTION 'void_reason is write-once';
        END IF;

        IF NEW.status IS DISTINCT FROM OLD.status THEN
            SELECT effective_tier INTO v_tier FROM public.get_company_tier(OLD.company_id);
            IF NOT public.validate_receipt_transition(OLD.status, NEW.status, v_tier) THEN
                RAISE EXCEPTION 'Invalid receipt status transition';
            END IF;
        END IF;

        IF OLD.status = 'pending' AND NEW.status = 'pending' THEN
            RAISE EXCEPTION 'Receipts are immutable while pending';
        END IF;

        IF OLD.status IN ('completed','voided') THEN
            IF NOT (OLD.status = 'completed' AND NEW.status = 'voided') THEN
                RAISE EXCEPTION 'Receipts are immutable once completed or voided';
            END IF;
        END IF;

        IF OLD.status = 'completed' AND NEW.status = 'voided' THEN
            IF NEW.void_reason IS NULL OR length(trim(NEW.void_reason)) < 10 THEN
                RAISE EXCEPTION 'Void reason required';
            END IF;
            IF NEW.notes IS DISTINCT FROM OLD.notes THEN
                RAISE EXCEPTION 'notes are immutable once completed';
            END IF;
            IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
                RAISE EXCEPTION 'supplier_id is immutable once completed';
            END IF;
            IF NEW.submitted_by IS DISTINCT FROM OLD.submitted_by THEN
                RAISE EXCEPTION 'submitted_by is immutable once completed';
            END IF;
            IF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
                RAISE EXCEPTION 'submitted_at is immutable once completed';
            END IF;
            IF NEW.rejected_by IS DISTINCT FROM OLD.rejected_by THEN
                RAISE EXCEPTION 'rejected_by is immutable once completed';
            END IF;
            IF NEW.rejected_at IS DISTINCT FROM OLD.rejected_at THEN
                RAISE EXCEPTION 'rejected_at is immutable once completed';
            END IF;
            IF NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason THEN
                RAISE EXCEPTION 'rejection_reason is immutable once completed';
            END IF;
            IF NEW.received_by IS DISTINCT FROM OLD.received_by THEN
                RAISE EXCEPTION 'received_by is immutable once completed';
            END IF;
            IF NEW.received_at IS DISTINCT FROM OLD.received_at THEN
                RAISE EXCEPTION 'received_at is immutable once completed';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_receipt(
    p_company_id UUID,
    p_purchase_order_id UUID DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt_id UUID;
    v_actor UUID := auth.uid();
    v_tier TEXT;
    v_receipt_number TEXT;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    IF v_actor IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Authentication required');
    END IF;

    SELECT effective_tier INTO v_tier FROM public.get_company_tier(p_company_id);
    IF v_tier = 'starter' THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(p_company_id, 'receiving:create') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF p_purchase_order_id IS NOT NULL AND to_regclass('public.purchase_orders') IS NOT NULL THEN
        PERFORM 1
        FROM public.purchase_orders
        WHERE id = p_purchase_order_id AND company_id = p_company_id;
        IF NOT FOUND THEN
            RETURN json_build_object('success', false, 'error', 'Purchase order not found');
        END IF;
    END IF;
    IF p_supplier_id IS NOT NULL THEN
        IF to_regclass('public.suppliers') IS NULL THEN
            RETURN json_build_object('success', false, 'error', 'Suppliers not supported');
        END IF;
        PERFORM 1
        FROM public.suppliers
        WHERE id = p_supplier_id AND company_id = p_company_id;
        IF NOT FOUND THEN
            RETURN json_build_object('success', false, 'error', 'Supplier not found');
        END IF;
    END IF;

    v_receipt_number := public.generate_receipt_number(p_company_id);

    INSERT INTO public.receipts (
        company_id,
        purchase_order_id,
        supplier_id,
        receipt_number,
        status,
        notes,
        created_at,
        created_by,
        updated_at,
        updated_by
    ) VALUES (
        p_company_id,
        p_purchase_order_id,
        p_supplier_id,
        v_receipt_number,
        'draft',
        p_notes,
        now(),
        v_actor,
        now(),
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

    RETURN json_build_object('success', true, 'receipt_id', v_receipt_id, 'status', 'draft');
END;
$$;

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
                quantity_removed,
                quantity_delta
            ) VALUES (
                v_receipt.company_id,
                v_actor,
                CURRENT_DATE,
                'update',
                'inventory_items',
                0,
                0,
                v_total_received
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
