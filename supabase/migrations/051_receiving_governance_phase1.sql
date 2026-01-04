-- Receiving governance alignment: schema, constraints, and RPCs

BEGIN;

-- -----------------------------------------------------------------------------
-- Receipt number generator
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_receipt_number(p_company_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_date TEXT := to_char(now(), 'YYYYMMDD');
    v_suffix TEXT;
    v_number TEXT;
    v_attempts INTEGER := 0;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Missing company_id';
    END IF;

    LOOP
        v_suffix := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4));
        v_number := 'RCV-' || v_date || '-' || v_suffix;
        IF NOT EXISTS (
            SELECT 1 FROM public.receipts
            WHERE company_id = p_company_id AND receipt_number = v_number
        ) THEN
            RETURN v_number;
        END IF;
        v_attempts := v_attempts + 1;
        IF v_attempts > 25 THEN
            RAISE EXCEPTION 'Failed to generate receipt number';
        END IF;
    END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- Receipts table alignment
-- -----------------------------------------------------------------------------
ALTER TABLE public.receipts
    ADD COLUMN IF NOT EXISTS receipt_number TEXT,
    ADD COLUMN IF NOT EXISTS supplier_id UUID,
    ADD COLUMN IF NOT EXISTS notes TEXT,
    ADD COLUMN IF NOT EXISTS submitted_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS rejected_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
    ADD COLUMN IF NOT EXISTS voided_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS void_reason TEXT,
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES auth.users(id);

ALTER TABLE public.receipts
    ALTER COLUMN purchase_order_id DROP NOT NULL,
    ALTER COLUMN received_by DROP NOT NULL,
    ALTER COLUMN status SET DEFAULT 'draft';

-- Optional foreign keys if related tables exist
DO $$
BEGIN
    IF to_regclass('public.purchase_orders') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'receipts_purchase_order_id_fkey'
              AND conrelid = 'public.receipts'::regclass
        ) THEN
            ALTER TABLE public.receipts
                ADD CONSTRAINT receipts_purchase_order_id_fkey
                FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE RESTRICT;
        END IF;
    END IF;
    IF to_regclass('public.suppliers') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'receipts_supplier_id_fkey'
              AND conrelid = 'public.receipts'::regclass
        ) THEN
            ALTER TABLE public.receipts
                ADD CONSTRAINT receipts_supplier_id_fkey
                FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;
        END IF;
    END IF;
END;
$$;

ALTER TABLE public.receipts DROP CONSTRAINT IF EXISTS receipts_status_check;
ALTER TABLE public.receipts
    ADD CONSTRAINT receipts_status_check
    CHECK (status IN ('draft','pending','completed','voided')) NOT VALID;
ALTER TABLE public.receipts VALIDATE CONSTRAINT receipts_status_check;

UPDATE public.receipts
SET receipt_number = COALESCE(receipt_number, public.generate_receipt_number(company_id))
WHERE receipt_number IS NULL;

UPDATE public.receipts
SET created_by = COALESCE(created_by, received_by),
    updated_by = COALESCE(updated_by, received_by),
    updated_at = COALESCE(updated_at, created_at, now())
WHERE created_by IS NULL OR updated_by IS NULL OR updated_at IS NULL;

ALTER TABLE public.receipts
    ALTER COLUMN receipt_number SET NOT NULL,
    ALTER COLUMN created_by SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL,
    ALTER COLUMN updated_by SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_receipts_company_number
    ON public.receipts(company_id, receipt_number);

CREATE INDEX IF NOT EXISTS idx_receipts_company_status
    ON public.receipts(company_id, status);

CREATE INDEX IF NOT EXISTS idx_receipts_po
    ON public.receipts(purchase_order_id)
    WHERE purchase_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_receipts_company_received_at
    ON public.receipts(company_id, received_at)
    WHERE received_at IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Receipt lines table alignment
-- -----------------------------------------------------------------------------
ALTER TABLE public.receipt_lines
    RENAME COLUMN qty_received TO received_qty;

ALTER TABLE public.receipt_lines
    RENAME COLUMN qty_rejected TO rejected_qty;

ALTER TABLE public.receipt_lines
    ALTER COLUMN received_qty TYPE INTEGER USING received_qty::integer,
    ALTER COLUMN rejected_qty TYPE INTEGER USING rejected_qty::integer,
    ALTER COLUMN received_qty SET DEFAULT 0,
    ALTER COLUMN rejected_qty SET DEFAULT 0;

ALTER TABLE public.receipt_lines
    ADD COLUMN IF NOT EXISTS po_line_id UUID,
    ADD COLUMN IF NOT EXISTS expected_qty INTEGER,
    ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
    ADD COLUMN IF NOT EXISTS unit_cost NUMERIC(10,2),
    ADD COLUMN IF NOT EXISTS lot_number TEXT,
    ADD COLUMN IF NOT EXISTS expiration_date DATE,
    ADD COLUMN IF NOT EXISTS notes TEXT,
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES auth.users(id);

DO $$
BEGIN
    IF to_regclass('public.purchase_order_lines') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'receipt_lines_po_line_id_fkey'
              AND conrelid = 'public.receipt_lines'::regclass
        ) THEN
            ALTER TABLE public.receipt_lines
                ADD CONSTRAINT receipt_lines_po_line_id_fkey
                FOREIGN KEY (po_line_id) REFERENCES public.purchase_order_lines(id) ON DELETE RESTRICT;
        END IF;
    END IF;
END;
$$;

ALTER TABLE public.receipt_lines DROP CONSTRAINT IF EXISTS receipt_lines_qty_received_check;
ALTER TABLE public.receipt_lines DROP CONSTRAINT IF EXISTS receipt_lines_qty_rejected_check;
ALTER TABLE public.receipt_lines DROP CONSTRAINT IF EXISTS receipt_lines_rejection_reason_check;

ALTER TABLE public.receipt_lines
    ADD CONSTRAINT receipt_lines_received_qty_check CHECK (received_qty >= 0) NOT VALID,
    ADD CONSTRAINT receipt_lines_rejected_qty_check CHECK (rejected_qty >= 0) NOT VALID,
    ADD CONSTRAINT receipt_lines_expected_qty_check CHECK (expected_qty IS NULL OR expected_qty >= 0) NOT VALID,
    ADD CONSTRAINT receipt_lines_rejection_reason_check
        CHECK (rejected_qty = 0 OR (rejection_reason IS NOT NULL AND length(trim(rejection_reason)) > 0)) NOT VALID;

ALTER TABLE public.receipt_lines VALIDATE CONSTRAINT receipt_lines_received_qty_check;
ALTER TABLE public.receipt_lines VALIDATE CONSTRAINT receipt_lines_rejected_qty_check;
ALTER TABLE public.receipt_lines VALIDATE CONSTRAINT receipt_lines_expected_qty_check;
ALTER TABLE public.receipt_lines VALIDATE CONSTRAINT receipt_lines_rejection_reason_check;

UPDATE public.receipt_lines rl
SET created_by = COALESCE(rl.created_by, r.received_by),
    updated_by = COALESCE(rl.updated_by, r.received_by),
    updated_at = COALESCE(rl.updated_at, rl.created_at, now())
FROM public.receipts r
WHERE rl.receipt_id = r.id
  AND (rl.created_by IS NULL OR rl.updated_by IS NULL OR rl.updated_at IS NULL);

ALTER TABLE public.receipt_lines
    ALTER COLUMN created_by SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL,
    ALTER COLUMN updated_by SET NOT NULL;

ALTER TABLE public.receipt_lines DROP CONSTRAINT IF EXISTS receipt_lines_unique_item;

CREATE INDEX IF NOT EXISTS idx_receipt_lines_po_line_id
    ON public.receipt_lines(po_line_id)
    WHERE po_line_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- updated_at triggers
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS update_receipts_updated_at ON public.receipts;
CREATE TRIGGER update_receipts_updated_at
    BEFORE UPDATE ON public.receipts
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS update_receipt_lines_updated_at ON public.receipt_lines;
CREATE TRIGGER update_receipt_lines_updated_at
    BEFORE UPDATE ON public.receipt_lines
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- -----------------------------------------------------------------------------
-- Immutability and write-once enforcement
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_receipt_write_once()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
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

DROP TRIGGER IF EXISTS enforce_receipt_write_once ON public.receipts;
CREATE TRIGGER enforce_receipt_write_once
    BEFORE UPDATE OR DELETE ON public.receipts
    FOR EACH ROW EXECUTE FUNCTION public.enforce_receipt_write_once();

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

DROP TRIGGER IF EXISTS enforce_receipt_line_immutability ON public.receipt_lines;
CREATE TRIGGER enforce_receipt_line_immutability
    BEFORE INSERT OR UPDATE OR DELETE ON public.receipt_lines
    FOR EACH ROW EXECUTE FUNCTION public.enforce_receipt_line_immutability();

-- -----------------------------------------------------------------------------
-- Transition validation helper
-- -----------------------------------------------------------------------------
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
BEGIN
    RETURN CASE
        WHEN p_current_status = 'draft' AND p_next_status = 'pending'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN p_current_status = 'draft' AND p_next_status = 'completed'
            AND v_tier = 'professional' THEN true
        WHEN p_current_status = 'pending' AND p_next_status = 'completed'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN p_current_status = 'pending' AND p_next_status = 'draft'
            AND v_tier IN ('business','enterprise') THEN true
        WHEN p_current_status = 'completed' AND p_next_status = 'voided'
            AND v_tier = 'enterprise' THEN true
        ELSE false
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- Receipt RPCs (create, add/update lines, transition status)
-- -----------------------------------------------------------------------------
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

    v_tier := public.get_company_tier(p_company_id);
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

GRANT EXECUTE ON FUNCTION public.create_receipt(UUID, UUID, TEXT, UUID) TO authenticated;

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

    IF v_receipt.status <> 'draft' THEN
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

CREATE OR REPLACE FUNCTION public.upsert_receipt_line(
    p_receipt_id UUID,
    p_item_id UUID,
    p_received_qty INTEGER,
    p_rejected_qty INTEGER DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_line_id UUID;
BEGIN
    SELECT id
    INTO v_line_id
    FROM public.receipt_lines
    WHERE receipt_id = p_receipt_id AND item_id = p_item_id
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_line_id IS NOT NULL THEN
        RETURN public.update_receipt_line(
            p_receipt_id,
            v_line_id,
            p_received_qty,
            NULL,
            p_rejected_qty,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL
        );
    END IF;

    RETURN public.add_receipt_line(
        p_receipt_id,
        p_item_id,
        p_received_qty,
        NULL,
        p_rejected_qty,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_receipt_line(UUID, UUID, INTEGER, INTEGER) TO authenticated;

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

    v_tier := public.get_company_tier(v_receipt.company_id);
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
            jsonb_build_object('lines_count', v_line_count)
        );
        IF v_total_received > 0 THEN
            INSERT INTO public.action_metrics (
                company_id,
                user_id,
                metric_date,
                action_type,
                table_name,
                action_count,
                records_affected,
                quantity_added
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

GRANT EXECUTE ON FUNCTION public.transition_receipt_status(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.complete_receipt(p_receipt_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.transition_receipt_status(p_receipt_id, 'completed', NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_receipt(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.void_receipt(p_receipt_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.transition_receipt_status(p_receipt_id, 'voided', p_reason);
END;
$$;

GRANT EXECUTE ON FUNCTION public.void_receipt(UUID, TEXT) TO authenticated;

COMMIT;
