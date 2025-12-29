-- Inventory seeding RPC (super_user only)
-- Feature IDs: inventory.seeding.super_user

BEGIN;

CREATE OR REPLACE FUNCTION public.seed_company_inventory(
    p_source_company_id UUID,
    p_target_company_id UUID,
    p_mode TEXT DEFAULT 'items_only',
    p_dedupe_key TEXT DEFAULT 'sku'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_mode TEXT := lower(trim(COALESCE(p_mode, '')));
    v_dedupe_key TEXT := lower(trim(COALESCE(p_dedupe_key, '')));
    v_items_copied INTEGER := 0;
    v_seed_run_id UUID;
    v_actor UUID := auth.uid();
    v_now TIMESTAMPTZ := now();
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_source_company_id IS NULL OR p_target_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Missing company id');
    END IF;

    IF p_source_company_id = p_target_company_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source and target must differ');
    END IF;

    IF v_mode <> 'items_only' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid mode');
    END IF;

    IF v_dedupe_key NOT IN ('sku','name') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid dedupe key');
    END IF;

    -- Lock target company to serialize seeding attempts.
    PERFORM 1 FROM public.companies WHERE id = p_target_company_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target company not found');
    END IF;

    PERFORM 1 FROM public.companies WHERE id = p_source_company_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source company not found');
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.inventory_seed_runs
        WHERE target_company_id = p_target_company_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target already seeded');
    END IF;

    WITH source_raw AS (
        SELECT
            i.name,
            i.description,
            i.sku,
            i.unit_of_measure,
            i.is_active,
            i.reorder_point,
            i.reorder_quantity,
            lower(trim(i.name)) AS name_key,
            NULLIF(lower(trim(COALESCE(i.sku, ''))), '') AS sku_key,
            CASE
                WHEN v_dedupe_key = 'name' THEN lower(trim(i.name))
                WHEN v_dedupe_key = 'sku' AND NULLIF(trim(COALESCE(i.sku, '')), '') IS NOT NULL
                    THEN lower(trim(i.sku))
                ELSE lower(trim(i.name))
            END AS dedupe_value
        FROM public.inventory_items i
        WHERE i.company_id = p_source_company_id
          AND i.deleted_at IS NULL
    ),
    source_deduped AS (
        SELECT DISTINCT ON (dedupe_value)
            name,
            description,
            sku,
            unit_of_measure,
            is_active,
            reorder_point,
            reorder_quantity,
            name_key,
            sku_key
        FROM source_raw
        WHERE name IS NOT NULL AND dedupe_value IS NOT NULL
        ORDER BY dedupe_value, name
    ),
    to_insert AS (
        SELECT s.*
        FROM source_deduped s
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.inventory_items t
            WHERE t.company_id = p_target_company_id
              AND t.deleted_at IS NULL
              AND (
                lower(trim(t.name)) = s.name_key
                OR (s.sku_key IS NOT NULL AND NULLIF(lower(trim(COALESCE(t.sku, ''))), '') = s.sku_key)
              )
        )
    ),
    ins AS (
        INSERT INTO public.inventory_items (
            company_id,
            name,
            description,
            sku,
            unit_of_measure,
            is_active,
            reorder_point,
            reorder_quantity,
            created_by
        )
        SELECT
            p_target_company_id,
            name,
            description,
            sku,
            unit_of_measure,
            is_active,
            reorder_point,
            reorder_quantity,
            v_actor
        FROM to_insert
        RETURNING id
    )
    SELECT COUNT(*) INTO v_items_copied FROM ins;

    INSERT INTO public.inventory_seed_runs (
        source_company_id,
        target_company_id,
        mode,
        dedupe_key,
        items_copied_count,
        created_by,
        created_at
    ) VALUES (
        p_source_company_id,
        p_target_company_id,
        v_mode,
        v_dedupe_key,
        v_items_copied,
        v_actor,
        v_now
    ) RETURNING id INTO v_seed_run_id;

    INSERT INTO public.audit_log (
        action,
        table_name,
        record_id,
        company_id,
        user_id,
        new_values
    ) VALUES (
        'INSERT',
        'inventory_seed_events',
        v_seed_run_id,
        p_target_company_id,
        v_actor,
        jsonb_build_object(
            'event_name', 'inventory_seeded',
            'actor_user_id', v_actor,
            'source_company_id', p_source_company_id,
            'target_company_id', p_target_company_id,
            'mode', v_mode,
            'dedupe_key', v_dedupe_key,
            'items_copied_count', v_items_copied,
            'timestamp', v_now
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'seed_run_id', v_seed_run_id,
        'items_copied_count', v_items_copied
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.seed_company_inventory(UUID, UUID, TEXT, TEXT) TO authenticated;

COMMIT;
