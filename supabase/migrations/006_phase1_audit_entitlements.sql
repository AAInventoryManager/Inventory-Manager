-- Phase 1 remediation: audit log entitlements
-- Feature IDs: inventory.audit.log, inventory.audit.undo

-- Audit log RLS: enforce tier + permission
DROP POLICY IF EXISTS "Admins can view audit log" ON public.audit_log;
DROP POLICY IF EXISTS "Audit log access" ON public.audit_log;
CREATE POLICY "Audit log access"
    ON public.audit_log FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('enterprise')
        AND public.check_permission(company_id, 'audit_log:view')
    );

-- Audit log RPC: enforce tier + permission
CREATE OR REPLACE FUNCTION public.get_audit_log(
    p_company_id UUID,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_table_name TEXT DEFAULT NULL,
    p_action TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID, action TEXT, table_name TEXT, record_id UUID,
    user_email TEXT, user_role TEXT, old_values JSONB, new_values JSONB,
    changed_fields TEXT[], created_at TIMESTAMPTZ, is_rolled_back BOOLEAN, rolled_back_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF public.get_company_tier(p_company_id) NOT IN ('enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(p_company_id, 'audit_log:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    RETURN QUERY
    SELECT 
        a.id, a.action, a.table_name, a.record_id,
        a.user_email, a.user_role, a.old_values, a.new_values,
        a.changed_fields, a.created_at, (a.rolled_back_at IS NOT NULL), a.rolled_back_at
    FROM public.audit_log a
    WHERE a.company_id = p_company_id
    AND (p_table_name IS NULL OR a.table_name = p_table_name)
    AND (p_action IS NULL OR a.action = p_action)
    ORDER BY a.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- Undo action RPC: enforce tier + permission
CREATE OR REPLACE FUNCTION public.undo_action(p_audit_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_audit RECORD;
    v_required_permission TEXT;
BEGIN
    SELECT * INTO v_audit
    FROM public.audit_log
    WHERE id = p_audit_id AND rolled_back_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Audit entry not found or already rolled back');
    END IF;

    IF public.get_company_tier(v_audit.company_id) NOT IN ('enterprise') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_audit.company_id, 'audit_log:view') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_audit.action IN ('DELETE', 'BULK_DELETE') THEN
        v_required_permission := 'items:restore';
    ELSIF v_audit.action = 'UPDATE' THEN
        v_required_permission := 'items:edit';
    ELSIF v_audit.action = 'INSERT' THEN
        v_required_permission := 'items:delete';
    ELSE
        RETURN json_build_object('success', false, 'error', 'Cannot undo this action type');
    END IF;

    IF v_required_permission IS NOT NULL AND NOT public.check_permission(v_audit.company_id, v_required_permission) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    CASE v_audit.action
        WHEN 'DELETE', 'BULK_DELETE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                UPDATE public.inventory_items
                SET 
                    deleted_at = NULL,
                    deleted_by = NULL,
                    name = COALESCE(v_audit.old_values->>'name', name),
                    description = COALESCE(v_audit.old_values->>'description', description),
                    quantity = COALESCE((v_audit.old_values->>'quantity')::integer, quantity)
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
            
        WHEN 'UPDATE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                UPDATE public.inventory_items
                SET 
                    name = COALESCE(v_audit.old_values->>'name', name),
                    description = COALESCE(v_audit.old_values->>'description', description),
                    quantity = COALESCE((v_audit.old_values->>'quantity')::integer, quantity),
                    sku = v_audit.old_values->>'sku',
                    updated_at = now()
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
            
        WHEN 'INSERT' THEN
            IF v_audit.table_name = 'inventory_items' THEN
                UPDATE public.inventory_items
                SET deleted_at = now(), deleted_by = auth.uid()
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
    END CASE;

    UPDATE public.audit_log
    SET rolled_back_at = now(), rolled_back_by = auth.uid(), rollback_reason = p_reason
    WHERE id = p_audit_id;
    
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, reason, old_values)
    VALUES ('ROLLBACK', v_audit.table_name, v_audit.record_id, v_audit.company_id, auth.uid(),
        'Undo of action ' || v_audit.id::text,
        jsonb_build_object('original_audit_id', p_audit_id, 'original_action', v_audit.action));
    
    RETURN json_build_object('success', true, 'message', 'Action undone');
END;
$$;
