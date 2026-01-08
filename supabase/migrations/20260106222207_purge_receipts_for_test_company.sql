-- Allow test-environment receipt cleanup via explicit purge mode.

CREATE OR REPLACE FUNCTION public.enforce_receipt_write_once()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF current_setting('app.purge_mode', true) = 'on' THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Receipts cannot be deleted';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.receipt_number IS DISTINCT FROM OLD.receipt_number THEN
            RAISE EXCEPTION 'receipt_number is write-once';
        END IF;
        IF NEW.company_id IS DISTINCT FROM OLD.company_id THEN
            RAISE EXCEPTION 'company_id is write-once';
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
            IF NOT public.validate_receipt_transition(OLD.status, NEW.status, public.get_company_tier(OLD.company_id)) THEN
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

CREATE OR REPLACE FUNCTION public.enforce_receipt_line_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('app.purge_mode', true) = 'on' THEN
        RETURN OLD;
    END IF;

    SELECT status INTO v_status FROM public.receipts WHERE id = COALESCE(NEW.receipt_id, OLD.receipt_id);
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Receipt not found';
    END IF;

    IF v_status <> 'draft' THEN
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
        IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'created_at is write-once';
        END IF;
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            RAISE EXCEPTION 'created_by is write-once';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_company_receiving(
    p_company_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted_lines INTEGER := 0;
    v_deleted_receipts INTEGER := 0;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company id required');
    END IF;

    IF NOT public.is_company_test_environment(p_company_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target company must be test environment');
    END IF;

    PERFORM set_config('app.purge_mode', 'on', true);

    DELETE FROM public.receipt_lines rl
    USING public.receipts r
    WHERE rl.receipt_id = r.id
      AND r.company_id = p_company_id;

    GET DIAGNOSTICS v_deleted_lines = ROW_COUNT;

    DELETE FROM public.receipts
    WHERE company_id = p_company_id;

    GET DIAGNOSTICS v_deleted_receipts = ROW_COUNT;

    PERFORM set_config('app.purge_mode', 'off', true);

    RETURN jsonb_build_object(
        'success', true,
        'deleted_receipt_lines', v_deleted_lines,
        'deleted_receipts', v_deleted_receipts
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('app.purge_mode', 'off', true);
        RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.purge_company_receiving(UUID) TO authenticated;
