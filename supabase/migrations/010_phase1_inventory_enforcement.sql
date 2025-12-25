-- Phase 1 remediation: inventory core & adjustments entitlements
-- Feature IDs: inventory.inventory.core, inventory.inventory.batch_edit,
--              inventory.inventory.import_export, inventory.inventory.trash

-- Inventory items RLS: permission enforcement
DROP POLICY IF EXISTS "Users can view active inventory" ON public.inventory_items;
CREATE POLICY "Users can view active inventory"
    ON public.inventory_items FOR SELECT
    USING (
        public.check_permission(company_id, 'items:view')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Admins can view deleted inventory" ON public.inventory_items;
CREATE POLICY "Admins can view deleted inventory"
    ON public.inventory_items FOR SELECT
    USING (
        (
            public.check_permission(company_id, 'items:delete')
            OR public.check_permission(company_id, 'items:restore')
        )
        AND deleted_at IS NOT NULL
    );

DROP POLICY IF EXISTS "Writers can create inventory" ON public.inventory_items;
CREATE POLICY "Writers can create inventory"
    ON public.inventory_items FOR INSERT
    WITH CHECK (
        public.check_permission(company_id, 'items:create')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Writers can update inventory" ON public.inventory_items;
CREATE POLICY "Writers can update inventory"
    ON public.inventory_items FOR UPDATE
    USING (
        public.check_permission(company_id, 'items:edit')
        AND deleted_at IS NULL
    )
    WITH CHECK (
        public.check_permission(company_id, 'items:edit')
        AND deleted_at IS NULL
    );

-- Inventory trash RPCs: permission enforcement
CREATE OR REPLACE FUNCTION public.soft_delete_item(p_item_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_quantity INTEGER;
BEGIN
    SELECT company_id, quantity INTO v_company_id, v_quantity
    FROM public.inventory_items
    WHERE id = p_item_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Item not found');
    END IF;

    IF NOT public.check_permission(v_company_id, 'items:delete') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = p_item_id
    AND company_id = v_company_id;

    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected, quantity_removed
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'delete', 'inventory_items',
        1, 1, COALESCE(v_quantity, 0)
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1,
        quantity_removed = action_metrics.quantity_removed + EXCLUDED.quantity_removed;

    RETURN json_build_object('success', true, 'message', 'Item moved to trash');
END;
$$;

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
    SELECT COUNT(DISTINCT company_id), MIN(company_id::text)::uuid, COALESCE(SUM(quantity), 0)
    INTO v_company_count, v_company_id, v_total_quantity
    FROM public.inventory_items
    WHERE id = ANY(p_item_ids) AND deleted_at IS NULL;

    IF v_company_count IS NULL OR v_company_count = 0 THEN
        RETURN json_build_object('success', false, 'error', 'No valid items found');
    END IF;

    IF v_company_count != 1 THEN
        RETURN json_build_object('success', false, 'error', 'Invalid item selection');
    END IF;

    IF NOT public.check_permission(v_company_id, 'items:delete') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    PERFORM public.create_snapshot(
        v_company_id,
        'Pre-Bulk Delete Backup',
        'Automatic backup before deleting ' || array_length(p_item_ids, 1) || ' items',
        'pre_bulk_delete'
    );

    UPDATE public.inventory_items
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = ANY(p_item_ids)
    AND company_id = v_company_id
    AND deleted_at IS NULL;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('BULK_DELETE', 'inventory_items', p_item_ids[1], v_company_id, auth.uid(),
        jsonb_build_object('deleted_ids', p_item_ids, 'count', v_count));

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

CREATE OR REPLACE FUNCTION public.restore_item(p_item_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_quantity INTEGER;
BEGIN
    SELECT company_id, quantity INTO v_company_id, v_quantity
    FROM public.inventory_items
    WHERE id = p_item_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Deleted item not found');
    END IF;

    IF NOT public.check_permission(v_company_id, 'items:restore') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.inventory_items
    SET deleted_at = NULL, deleted_by = NULL
    WHERE id = p_item_id
    AND company_id = v_company_id;

    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('RESTORE', 'inventory_items', p_item_id, v_company_id, auth.uid(),
        jsonb_build_object('restored_at', now()));

    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected, quantity_added
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'restore', 'inventory_items',
        1, 1, COALESCE(v_quantity, 0)
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1,
        quantity_added = action_metrics.quantity_added + EXCLUDED.quantity_added;

    RETURN json_build_object('success', true, 'message', 'Item restored');
END;
$$;

CREATE OR REPLACE FUNCTION public.get_deleted_items(p_company_id UUID)
RETURNS TABLE (id UUID, name TEXT, description TEXT, quantity INTEGER, deleted_at TIMESTAMPTZ, deleted_by_email TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT (
        public.check_permission(p_company_id, 'items:delete')
        OR public.check_permission(p_company_id, 'items:restore')
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT i.id, i.name, i.description, i.quantity, i.deleted_at, u.email
    FROM public.inventory_items i
    LEFT JOIN auth.users u ON u.id = i.deleted_by
    WHERE i.company_id = p_company_id AND i.deleted_at IS NOT NULL
    ORDER BY i.deleted_at DESC;
END;
$$;

-- Bulk import RPC (Professional+)
CREATE OR REPLACE FUNCTION public.bulk_upsert_inventory_items(
    p_company_id UUID,
    p_items JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted INTEGER := 0;
    v_updated INTEGER := 0;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    IF public.get_company_tier(p_company_id) NOT IN ('professional','business','enterprise') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(p_company_id, 'items:import') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RETURN json_build_object('success', false, 'error', 'Invalid items payload');
    END IF;

    WITH raw AS (
        SELECT
            NULLIF(trim(value->>'name'), '') AS name,
            trim(COALESCE(value->>'desc', value->>'description', '')) AS description,
            CASE
                WHEN (value->>'qty') ~ '^-?\\d+$' THEN (value->>'qty')::int
                ELSE 0
            END AS quantity
        FROM jsonb_array_elements(p_items) value
    ),
    cleaned AS (
        SELECT DISTINCT ON (lower(name))
            name,
            description,
            quantity
        FROM raw
        WHERE name IS NOT NULL
        ORDER BY lower(name)
    ),
    existing AS (
        SELECT id, name, description
        FROM public.inventory_items
        WHERE company_id = p_company_id AND deleted_at IS NULL
    ),
    to_insert AS (
        SELECT c.name, c.description, c.quantity
        FROM cleaned c
        LEFT JOIN existing e ON lower(e.name) = lower(c.name)
        WHERE e.id IS NULL
    ),
    to_update AS (
        SELECT e.id, c.name,
            CASE WHEN c.description = '' THEN e.description ELSE c.description END AS description,
            c.quantity
        FROM cleaned c
        JOIN existing e ON lower(e.name) = lower(c.name)
    ),
    ins AS (
        INSERT INTO public.inventory_items (
            company_id, name, description, quantity, reorder_enabled, created_by
        )
        SELECT p_company_id, name, description, quantity, true, auth.uid()
        FROM to_insert
        RETURNING id
    ),
    upd AS (
        UPDATE public.inventory_items i
        SET name = u.name,
            description = u.description,
            quantity = u.quantity
        FROM to_update u
        WHERE i.id = u.id
        RETURNING i.id
    )
    SELECT
        (SELECT COUNT(*) FROM ins),
        (SELECT COUNT(*) FROM upd)
    INTO v_inserted, v_updated;

    RETURN json_build_object(
        'success', true,
        'inserted', v_inserted,
        'updated', v_updated,
        'total', v_inserted + v_updated
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.bulk_upsert_inventory_items(UUID, JSONB) TO authenticated;

-- Inventory export RPC (Professional+)
CREATE OR REPLACE FUNCTION public.export_inventory_items(p_company_id UUID)
RETURNS TABLE (id UUID, name TEXT, description TEXT, quantity INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF p_company_id IS NULL THEN
        RETURN;
    END IF;

    IF public.get_company_tier(p_company_id) NOT IN ('professional','business','enterprise') THEN
        RETURN;
    END IF;

    IF NOT public.check_permission(p_company_id, 'items:export') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT i.id, i.name, i.description, i.quantity
    FROM public.inventory_items i
    WHERE i.company_id = p_company_id AND i.deleted_at IS NULL
    ORDER BY i.name ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.export_inventory_items(UUID) TO authenticated;
