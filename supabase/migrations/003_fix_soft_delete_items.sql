-- Fix MIN(uuid) error in soft_delete_items
CREATE OR REPLACE FUNCTION public.soft_delete_items(p_item_ids UUID[])
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_count INTEGER;
    v_company_count INTEGER;
    v_total_quantity INTEGER;
BEGIN
    -- SECURITY: Verify ALL items belong to exactly ONE company
    SELECT COUNT(DISTINCT company_id), MIN(company_id::text)::uuid, COALESCE(SUM(quantity), 0)
    INTO v_company_count, v_company_id, v_total_quantity
    FROM public.inventory_items
    WHERE id = ANY(p_item_ids) AND deleted_at IS NULL;
    
    -- Reject if items span multiple companies or no items found
    IF v_company_count IS NULL OR v_company_count = 0 THEN
        RETURN json_build_object('success', false, 'error', 'No valid items found');
    END IF;
    
    IF v_company_count != 1 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid item selection');
    END IF;
    
    -- Verify user has delete permission for THIS company
    IF NOT public.user_can_delete(v_company_id) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;
    
    -- Create snapshot before bulk delete
    PERFORM public.create_snapshot(
        v_company_id, 
        'Pre-Bulk Delete Backup', 
        'Automatic backup before deleting ' || array_length(p_item_ids, 1) || ' items',
        'pre_bulk_delete'
    );
    
    -- SECURITY: Only delete items that belong to the verified company
    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = ANY(p_item_ids)
    AND company_id = v_company_id  -- CRITICAL: Company guard
    AND deleted_at IS NULL;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    -- Log bulk action to audit
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('BULK_DELETE', 'inventory_items', p_item_ids[1], v_company_id, auth.uid(),
        jsonb_build_object('deleted_ids', p_item_ids, 'count', v_count));
    
    -- Log to action_metrics as DELETE (not update)
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected, quantity_removed
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'delete', 'inventory_items',
        1, v_count, v_total_quantity
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET 
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + EXCLUDED.records_affected,
        quantity_removed = action_metrics.quantity_removed + EXCLUDED.quantity_removed;
    
    RETURN json_build_object('success', true, 'deleted_count', v_count);
END;
$$;
