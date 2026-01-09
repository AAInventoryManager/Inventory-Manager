-- Fix incorrect table reference in add_receipt_line function
-- The function was checking for 'purchase_order_lines' but the actual table is 'purchase_order_items'

BEGIN;

CREATE OR REPLACE FUNCTION public.add_receipt_line(
    p_receipt_id UUID,
    p_item_id UUID,
    p_po_line_id UUID DEFAULT NULL,
    p_expected_qty INTEGER DEFAULT 0,
    p_received_qty INTEGER DEFAULT 0,
    p_rejected_qty INTEGER DEFAULT 0,
    p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_receipt RECORD;
    v_line_id UUID;
BEGIN
    SELECT id, purchase_order_id, company_id, status
    INTO v_receipt
    FROM public.receipts
    WHERE id = p_receipt_id;
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Receipt not found');
    END IF;

    IF v_receipt.status NOT IN ('draft', 'blocked_by_plan') THEN
        RETURN json_build_object('success', false, 'error', 'Receipt is not editable');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.inventory_items
        WHERE id = p_item_id AND company_id = v_receipt.company_id
    ) THEN
        RETURN json_build_object('success', false, 'error', 'Item not found');
    END IF;

    IF v_receipt.purchase_order_id IS NOT NULL AND p_po_line_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'PO line required for PO receipt');
    END IF;
    IF v_receipt.purchase_order_id IS NULL AND p_po_line_id IS NOT NULL THEN
        RETURN json_build_object('success', false, 'error', 'PO line not allowed for non-PO receipt');
    END IF;
    IF p_po_line_id IS NOT NULL THEN
        -- Fixed: check for purchase_order_items instead of purchase_order_lines
        IF to_regclass('public.purchase_order_items') IS NULL THEN
            RETURN json_build_object('success', false, 'error', 'Purchase order items table not found');
        END IF;
        PERFORM 1
        FROM public.purchase_order_items
        WHERE id = p_po_line_id
          AND purchase_order_id = v_receipt.purchase_order_id;
        IF NOT FOUND THEN
            RETURN json_build_object('success', false, 'error', 'PO line item not found');
        END IF;
    END IF;

    INSERT INTO public.receipt_lines (
        receipt_id,
        item_id,
        po_line_id,
        expected_qty,
        received_qty,
        rejected_qty,
        rejection_reason
    ) VALUES (
        p_receipt_id,
        p_item_id,
        p_po_line_id,
        COALESCE(p_expected_qty, 0),
        COALESCE(p_received_qty, 0),
        COALESCE(p_rejected_qty, 0),
        NULLIF(trim(COALESCE(p_rejection_reason, '')), '')
    )
    RETURNING id INTO v_line_id;

    RETURN json_build_object(
        'success', true,
        'line_id', v_line_id
    );
END;
$$;

COMMIT;
