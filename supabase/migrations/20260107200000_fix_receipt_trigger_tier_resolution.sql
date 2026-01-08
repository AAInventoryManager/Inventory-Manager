-- Fix tier resolution in enforce_receipt_write_once trigger
-- The get_company_tier function returns TABLE, not TEXT, so we must select from it

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

NOTIFY pgrst, 'reload schema';

COMMIT;
