-- Enable receipt deletes for admins/super users via RPC with purge mode.

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_receipt_line_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF current_setting('app.purge_mode', true) = 'on' THEN
            RETURN OLD;
        END IF;
    END IF;

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

DROP POLICY IF EXISTS "receipts_company_delete" ON public.receipts;
CREATE POLICY "receipts_company_delete"
ON public.receipts
FOR DELETE
USING (
    public.user_can_delete(company_id)
    AND public.normalize_receipt_status(status) IN ('draft','blocked_by_plan','voided')
);

CREATE OR REPLACE FUNCTION public.delete_receipts(
    p_receipt_ids UUID[],
    p_force BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ids UUID[];
    v_missing_count INTEGER := 0;
    v_deleted_receipts INTEGER := 0;
    v_deleted_lines INTEGER := 0;
    v_deleted_attachments INTEGER := 0;
    v_requires_force BOOLEAN := false;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF p_receipt_ids IS NULL OR array_length(p_receipt_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No receipts selected');
    END IF;

    SELECT array_agg(id) INTO v_ids
    FROM public.receipts
    WHERE id = ANY(p_receipt_ids);

    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Receipts not found');
    END IF;

    v_missing_count := array_length(p_receipt_ids, 1) - array_length(v_ids, 1);

    IF EXISTS (
        SELECT 1 FROM public.receipts r
        WHERE r.id = ANY(v_ids)
          AND NOT public.user_can_delete(r.company_id)
    ) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.receipts r
        WHERE r.id = ANY(v_ids)
          AND public.normalize_receipt_status(r.status) NOT IN ('draft','blocked_by_plan','voided')
    ) INTO v_requires_force;

    IF v_requires_force THEN
        IF NOT p_force THEN
            RAISE EXCEPTION 'Force delete required';
        END IF;
        IF NOT public.is_super_user() THEN
            RAISE EXCEPTION 'Force delete requires super user';
        END IF;
    END IF;

    PERFORM set_config('app.purge_mode', 'on', true);

    DELETE FROM public.receipt_lines rl
    USING public.receipts r
    WHERE rl.receipt_id = r.id
      AND r.id = ANY(v_ids);
    GET DIAGNOSTICS v_deleted_lines = ROW_COUNT;

    DELETE FROM public.receipt_attachments ra
    USING public.receipts r
    WHERE ra.receipt_id = r.id
      AND r.id = ANY(v_ids);
    GET DIAGNOSTICS v_deleted_attachments = ROW_COUNT;

    DELETE FROM public.receipts
    WHERE id = ANY(v_ids);
    GET DIAGNOSTICS v_deleted_receipts = ROW_COUNT;

    PERFORM set_config('app.purge_mode', 'off', true);

    RETURN jsonb_build_object(
        'success', true,
        'deleted_receipts', v_deleted_receipts,
        'deleted_receipt_lines', v_deleted_lines,
        'deleted_attachments', v_deleted_attachments,
        'missing', v_missing_count,
        'force', v_requires_force
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('app.purge_mode', 'off', true);
        RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_receipts(UUID[], BOOLEAN) TO authenticated;

COMMIT;
