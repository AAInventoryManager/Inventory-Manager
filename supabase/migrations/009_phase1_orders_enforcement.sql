-- Phase 1 remediation: procurement & orders entitlements
-- Feature IDs: inventory.orders.cart, inventory.orders.email_send, inventory.orders.history,
--              inventory.orders.recipients, inventory.orders.trash

-- Orders RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view active orders" ON public.orders;
CREATE POLICY "Users can view active orders"
    ON public.orders FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:view')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Admins can view deleted orders" ON public.orders;
CREATE POLICY "Admins can view deleted orders"
    ON public.orders FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:delete')
        AND deleted_at IS NOT NULL
    );

DROP POLICY IF EXISTS "Writers can create orders" ON public.orders;
CREATE POLICY "Writers can create orders"
    ON public.orders FOR INSERT
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:create')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Writers can update orders" ON public.orders;
CREATE POLICY "Writers can update orders"
    ON public.orders FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:edit')
        AND deleted_at IS NULL
    )
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:edit')
        AND deleted_at IS NULL
    );

-- Order recipients RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view company recipients" ON public.order_recipients;
CREATE POLICY "Users can view company recipients"
    ON public.order_recipients FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:view')
    );

DROP POLICY IF EXISTS "Writers can create recipients" ON public.order_recipients;
CREATE POLICY "Writers can create recipients"
    ON public.order_recipients FOR INSERT
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:create')
    );

DROP POLICY IF EXISTS "Writers can update recipients" ON public.order_recipients;
CREATE POLICY "Writers can update recipients"
    ON public.order_recipients FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:edit')
    );

-- Order delete/restore RPCs: tier + permission enforcement
CREATE OR REPLACE FUNCTION public.soft_delete_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    -- Get company and verify order exists and is active
    SELECT company_id INTO v_company_id
    FROM public.orders
    WHERE id = p_order_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Order not found');
    END IF;

    IF public.get_company_tier(v_company_id) NOT IN ('business','enterprise') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_company_id, 'orders:delete') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    -- Soft delete with company guard
    UPDATE public.orders
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = p_order_id
    AND company_id = v_company_id;

    -- Log to action_metrics as DELETE
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'delete', 'orders',
        1, 1
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1;

    RETURN json_build_object('success', true, 'message', 'Order moved to trash');
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    SELECT company_id INTO v_company_id
    FROM public.orders
    WHERE id = p_order_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Deleted order not found');
    END IF;

    IF public.get_company_tier(v_company_id) NOT IN ('business','enterprise') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_company_id, 'orders:restore') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.orders
    SET deleted_at = NULL, deleted_by = NULL
    WHERE id = p_order_id
    AND company_id = v_company_id;

    -- Log to audit
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('RESTORE', 'orders', p_order_id, v_company_id, auth.uid(),
        jsonb_build_object('restored_at', now()));

    -- Log to action_metrics as RESTORE
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'restore', 'orders',
        1, 1
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1;

    RETURN json_build_object('success', true, 'message', 'Order restored');
END;
$$;
