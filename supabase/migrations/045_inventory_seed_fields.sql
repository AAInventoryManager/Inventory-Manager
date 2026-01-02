BEGIN;

ALTER TABLE public.inventory_seed_runs
  ADD COLUMN IF NOT EXISTS seed_fields TEXT[] DEFAULT ARRAY['items']::text[],
  ADD COLUMN IF NOT EXISTS items_updated_count INTEGER DEFAULT 0;

UPDATE public.inventory_seed_runs
SET seed_fields = ARRAY['items']::text[]
WHERE seed_fields IS NULL;

UPDATE public.inventory_seed_runs
SET items_updated_count = 0
WHERE items_updated_count IS NULL;

ALTER TABLE public.inventory_seed_runs
  ALTER COLUMN seed_fields SET NOT NULL;

ALTER TABLE public.inventory_seed_runs
  ALTER COLUMN items_updated_count SET NOT NULL;

ALTER TABLE public.inventory_seed_runs
  DROP CONSTRAINT IF EXISTS inventory_seed_runs_target_company_unique;

ALTER TABLE public.inventory_seed_runs
  DROP CONSTRAINT IF EXISTS inventory_seed_runs_mode_check;

ALTER TABLE public.inventory_seed_runs
  ADD CONSTRAINT inventory_seed_runs_mode_check
    CHECK (mode IN ('items_only','fields_only','items_and_fields'));

CREATE INDEX IF NOT EXISTS idx_inventory_seed_runs_target_company_id
  ON public.inventory_seed_runs(target_company_id);

DROP FUNCTION IF EXISTS public.seed_company_inventory(UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.seed_company_inventory(UUID, UUID, TEXT, TEXT, TEXT[]);

CREATE OR REPLACE FUNCTION public.seed_company_inventory(
    p_source_company_id UUID,
    p_target_company_id UUID,
    p_mode TEXT DEFAULT 'items_only',
    p_dedupe_key TEXT DEFAULT 'sku',
    p_seed_fields TEXT[] DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_mode TEXT := lower(trim(COALESCE(p_mode, '')));
    v_dedupe_key TEXT := lower(trim(COALESCE(p_dedupe_key, '')));
    v_seed_fields TEXT[];
    v_items_copied INTEGER := 0;
    v_items_updated INTEGER := 0;
    v_seed_run_id UUID;
    v_actor UUID := auth.uid();
    v_now TIMESTAMPTZ := now();
    v_items_requested BOOLEAN := false;
    v_has_field_updates BOOLEAN := false;
    v_do_on_hand BOOLEAN := false;
    v_do_description BOOLEAN := false;
    v_do_sku BOOLEAN := false;
    v_do_unit BOOLEAN := false;
    v_do_location BOOLEAN := false;
    v_do_category BOOLEAN := false;
    v_do_reorder_point BOOLEAN := false;
    v_do_reorder_qty BOOLEAN := false;
    v_do_reorder_enabled BOOLEAN := false;
    v_do_is_active BOOLEAN := false;
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

    IF v_dedupe_key NOT IN ('sku','name') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid dedupe key');
    END IF;

    IF p_seed_fields IS NOT NULL THEN
        SELECT ARRAY(
            SELECT DISTINCT f
            FROM (
                SELECT CASE
                    WHEN lower(trim(x)) IN ('items','item') THEN 'items'
                    WHEN lower(trim(x)) IN ('on_hand','onhand','quantity') THEN 'on_hand'
                    WHEN lower(trim(x)) IN ('description','desc') THEN 'description'
                    WHEN lower(trim(x)) = 'sku' THEN 'sku'
                    WHEN lower(trim(x)) IN ('unit_of_measure','uom','unit') THEN 'unit_of_measure'
                    WHEN lower(trim(x)) IN ('location','location_name') THEN 'location'
                    WHEN lower(trim(x)) IN ('category','category_name') THEN 'category'
                    WHEN lower(trim(x)) IN ('reorder_point','reorder') THEN 'reorder_point'
                    WHEN lower(trim(x)) IN ('reorder_qty','reorder_quantity') THEN 'reorder_qty'
                    WHEN lower(trim(x)) = 'reorder_enabled' THEN 'reorder_enabled'
                    WHEN lower(trim(x)) IN ('is_active','active') THEN 'is_active'
                    ELSE NULL
                END AS f
                FROM unnest(p_seed_fields) AS x
            ) AS cleaned
            WHERE f IS NOT NULL
        ) INTO v_seed_fields;
        IF v_seed_fields IS NULL OR array_length(v_seed_fields, 1) IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Invalid seed fields');
        END IF;
    END IF;

    IF v_seed_fields IS NULL OR array_length(v_seed_fields, 1) IS NULL THEN
        IF v_mode <> '' AND v_mode <> 'items_only' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Invalid mode');
        END IF;
        v_seed_fields := ARRAY['items']::text[];
    END IF;

    v_items_requested := 'items' = ANY(v_seed_fields);
    v_do_on_hand := 'on_hand' = ANY(v_seed_fields);
    v_do_description := 'description' = ANY(v_seed_fields);
    v_do_sku := 'sku' = ANY(v_seed_fields);
    v_do_unit := 'unit_of_measure' = ANY(v_seed_fields);
    v_do_location := 'location' = ANY(v_seed_fields);
    v_do_category := 'category' = ANY(v_seed_fields);
    v_do_reorder_point := 'reorder_point' = ANY(v_seed_fields);
    v_do_reorder_qty := 'reorder_qty' = ANY(v_seed_fields);
    v_do_reorder_enabled := 'reorder_enabled' = ANY(v_seed_fields);
    v_do_is_active := 'is_active' = ANY(v_seed_fields);
    v_has_field_updates := v_do_on_hand OR v_do_description OR v_do_sku OR v_do_unit
        OR v_do_location OR v_do_category OR v_do_reorder_point OR v_do_reorder_qty
        OR v_do_reorder_enabled OR v_do_is_active;

    IF NOT v_items_requested AND NOT v_has_field_updates THEN
        RETURN jsonb_build_object('success', false, 'error', 'No seed fields selected');
    END IF;

    IF v_items_requested AND v_has_field_updates THEN
        v_mode := 'items_and_fields';
    ELSIF v_items_requested THEN
        v_mode := 'items_only';
    ELSE
        v_mode := 'fields_only';
    END IF;

    PERFORM 1 FROM public.companies WHERE id = p_target_company_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target company not found');
    END IF;

    PERFORM 1 FROM public.companies WHERE id = p_source_company_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source company not found');
    END IF;

    IF NOT public.is_company_test_environment(p_target_company_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target company must be test environment');
    END IF;

    IF v_items_requested AND EXISTS (
        SELECT 1
        FROM public.inventory_seed_runs r
        WHERE r.target_company_id = p_target_company_id
          AND (
            r.seed_fields IS NULL
            OR r.seed_fields @> ARRAY['items']::text[]
            OR r.mode IN ('items_only','items_and_fields')
          )
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Items already seeded');
    END IF;

    IF v_items_requested THEN
        WITH source_raw AS (
            SELECT
                i.name,
                NULLIF(trim(i.description), '') AS description,
                NULLIF(trim(i.sku), '') AS sku,
                NULLIF(trim(i.unit_of_measure), '') AS unit_of_measure,
                i.is_active,
                i.reorder_point,
                i.reorder_quantity,
                i.reorder_enabled,
                i.quantity,
                lower(trim(i.name)) AS name_key,
                NULLIF(lower(trim(COALESCE(i.sku, ''))), '') AS sku_key,
                CASE
                    WHEN v_dedupe_key = 'name' THEN lower(trim(i.name))
                    WHEN v_dedupe_key = 'sku' AND NULLIF(trim(COALESCE(i.sku, '')), '') IS NOT NULL
                        THEN lower(trim(i.sku))
                    ELSE lower(trim(i.name))
                END AS dedupe_value,
                NULLIF(trim(c.name), '') AS category_name,
                NULLIF(trim(l.name), '') AS location_name,
                NULLIF(lower(trim(COALESCE(c.name, ''))), '') AS category_key,
                NULLIF(lower(trim(COALESCE(l.name, ''))), '') AS location_key
            FROM public.inventory_items i
            LEFT JOIN public.inventory_categories c ON c.id = i.category_id
            LEFT JOIN public.inventory_locations l ON l.id = i.location_id
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
                reorder_enabled,
                quantity,
                name_key,
                sku_key,
                dedupe_value,
                category_name,
                location_name,
                category_key,
                location_key
            FROM source_raw
            WHERE name IS NOT NULL AND dedupe_value IS NOT NULL
            ORDER BY dedupe_value, name
        ),
        category_seed AS (
            INSERT INTO public.inventory_categories (company_id, name, created_at, updated_at)
            SELECT
                p_target_company_id,
                s.category_name,
                v_now,
                v_now
            FROM (
                SELECT DISTINCT category_name, category_key
                FROM source_deduped
                WHERE category_key IS NOT NULL
            ) s
            WHERE v_do_category
              AND NOT EXISTS (
                SELECT 1
                FROM public.inventory_categories c
                WHERE c.company_id = p_target_company_id
                  AND c.deleted_at IS NULL
                  AND lower(trim(c.name)) = s.category_key
              )
            RETURNING id
        ),
        category_map AS (
            SELECT id, lower(trim(name)) AS name_key
            FROM public.inventory_categories
            WHERE company_id = p_target_company_id
              AND deleted_at IS NULL
        ),
        location_seed AS (
            INSERT INTO public.inventory_locations (company_id, name, is_active, created_by, created_at, updated_at)
            SELECT
                p_target_company_id,
                s.location_name,
                true,
                v_actor,
                v_now,
                v_now
            FROM (
                SELECT DISTINCT location_name, location_key
                FROM source_deduped
                WHERE location_key IS NOT NULL
            ) s
            WHERE v_do_location
              AND NOT EXISTS (
                SELECT 1
                FROM public.inventory_locations l
                WHERE l.company_id = p_target_company_id
                  AND l.deleted_at IS NULL
                  AND lower(trim(l.name)) = s.location_key
              )
            RETURNING id
        ),
        location_map AS (
            SELECT id, lower(trim(name)) AS name_key
            FROM public.inventory_locations
            WHERE company_id = p_target_company_id
              AND deleted_at IS NULL
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
                reorder_enabled,
                quantity,
                category_id,
                location_id,
                created_by
            )
            SELECT
                p_target_company_id,
                s.name,
                s.description,
                s.sku,
                COALESCE(s.unit_of_measure, 'each'),
                COALESCE(s.is_active, true),
                s.reorder_point,
                s.reorder_quantity,
                CASE WHEN v_do_reorder_enabled THEN COALESCE(s.reorder_enabled, false) ELSE false END,
                CASE WHEN v_do_on_hand THEN COALESCE(s.quantity, 0) ELSE 0 END,
                CASE WHEN v_do_category THEN c.id ELSE NULL END,
                CASE WHEN v_do_location THEN l.id ELSE NULL END,
                v_actor
            FROM to_insert s
            LEFT JOIN category_map c ON c.name_key = s.category_key
            LEFT JOIN location_map l ON l.name_key = s.location_key
            RETURNING id
        )
        SELECT COUNT(*) INTO v_items_copied FROM ins;
    END IF;

    IF v_has_field_updates THEN
        WITH source_raw AS (
            SELECT
                i.name,
                NULLIF(trim(i.description), '') AS description,
                NULLIF(trim(i.sku), '') AS sku,
                NULLIF(trim(i.unit_of_measure), '') AS unit_of_measure,
                i.is_active,
                i.reorder_point,
                i.reorder_quantity,
                i.reorder_enabled,
                i.quantity,
                lower(trim(i.name)) AS name_key,
                NULLIF(lower(trim(COALESCE(i.sku, ''))), '') AS sku_key,
                CASE
                    WHEN v_dedupe_key = 'name' THEN lower(trim(i.name))
                    WHEN v_dedupe_key = 'sku' AND NULLIF(trim(COALESCE(i.sku, '')), '') IS NOT NULL
                        THEN lower(trim(i.sku))
                    ELSE lower(trim(i.name))
                END AS dedupe_value,
                NULLIF(trim(c.name), '') AS category_name,
                NULLIF(trim(l.name), '') AS location_name,
                NULLIF(lower(trim(COALESCE(c.name, ''))), '') AS category_key,
                NULLIF(lower(trim(COALESCE(l.name, ''))), '') AS location_key
            FROM public.inventory_items i
            LEFT JOIN public.inventory_categories c ON c.id = i.category_id
            LEFT JOIN public.inventory_locations l ON l.id = i.location_id
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
                reorder_enabled,
                quantity,
                name_key,
                sku_key,
                dedupe_value,
                category_name,
                location_name,
                category_key,
                location_key
            FROM source_raw
            WHERE name IS NOT NULL AND dedupe_value IS NOT NULL
            ORDER BY dedupe_value, name
        ),
        category_seed AS (
            INSERT INTO public.inventory_categories (company_id, name, created_at, updated_at)
            SELECT
                p_target_company_id,
                s.category_name,
                v_now,
                v_now
            FROM (
                SELECT DISTINCT category_name, category_key
                FROM source_deduped
                WHERE category_key IS NOT NULL
            ) s
            WHERE v_do_category
              AND NOT EXISTS (
                SELECT 1
                FROM public.inventory_categories c
                WHERE c.company_id = p_target_company_id
                  AND c.deleted_at IS NULL
                  AND lower(trim(c.name)) = s.category_key
              )
            RETURNING id
        ),
        category_map AS (
            SELECT id, lower(trim(name)) AS name_key
            FROM public.inventory_categories
            WHERE company_id = p_target_company_id
              AND deleted_at IS NULL
        ),
        location_seed AS (
            INSERT INTO public.inventory_locations (company_id, name, is_active, created_by, created_at, updated_at)
            SELECT
                p_target_company_id,
                s.location_name,
                true,
                v_actor,
                v_now,
                v_now
            FROM (
                SELECT DISTINCT location_name, location_key
                FROM source_deduped
                WHERE location_key IS NOT NULL
            ) s
            WHERE v_do_location
              AND NOT EXISTS (
                SELECT 1
                FROM public.inventory_locations l
                WHERE l.company_id = p_target_company_id
                  AND l.deleted_at IS NULL
                  AND lower(trim(l.name)) = s.location_key
              )
            RETURNING id
        ),
        location_map AS (
            SELECT id, lower(trim(name)) AS name_key
            FROM public.inventory_locations
            WHERE company_id = p_target_company_id
              AND deleted_at IS NULL
        ),
        target_raw AS (
            SELECT
                t.id,
                CASE
                    WHEN v_dedupe_key = 'name' THEN lower(trim(t.name))
                    WHEN v_dedupe_key = 'sku' AND NULLIF(trim(COALESCE(t.sku, '')), '') IS NOT NULL
                        THEN lower(trim(t.sku))
                    ELSE lower(trim(t.name))
                END AS dedupe_value
            FROM public.inventory_items t
            WHERE t.company_id = p_target_company_id
              AND t.deleted_at IS NULL
        ),
        target_match AS (
            SELECT
                t.id,
                s.*,
                c.id AS category_id,
                l.id AS location_id
            FROM target_raw t
            JOIN source_deduped s ON s.dedupe_value = t.dedupe_value
            LEFT JOIN category_map c ON c.name_key = s.category_key
            LEFT JOIN location_map l ON l.name_key = s.location_key
        ),
        to_update AS (
            SELECT
                *,
                (
                    (v_do_on_hand AND quantity IS NOT NULL)
                    OR (v_do_description AND description IS NOT NULL)
                    OR (v_do_sku AND sku IS NOT NULL)
                    OR (v_do_unit AND unit_of_measure IS NOT NULL)
                    OR (v_do_reorder_point AND reorder_point IS NOT NULL)
                    OR (v_do_reorder_qty AND reorder_quantity IS NOT NULL)
                    OR (v_do_reorder_enabled AND reorder_enabled IS NOT NULL)
                    OR (v_do_is_active AND is_active IS NOT NULL)
                    OR (v_do_category AND category_id IS NOT NULL)
                    OR (v_do_location AND location_id IS NOT NULL)
                ) AS has_update
            FROM target_match
        ),
        upd AS (
            UPDATE public.inventory_items t
            SET
                quantity = CASE WHEN v_do_on_hand AND u.quantity IS NOT NULL THEN u.quantity ELSE t.quantity END,
                description = CASE WHEN v_do_description AND u.description IS NOT NULL THEN u.description ELSE t.description END,
                sku = CASE WHEN v_do_sku AND u.sku IS NOT NULL AND NOT EXISTS (
                    SELECT 1
                    FROM public.inventory_items x
                    WHERE x.company_id = p_target_company_id
                      AND x.deleted_at IS NULL
                      AND x.id <> t.id
                      AND NULLIF(lower(trim(COALESCE(x.sku, ''))), '') = u.sku_key
                ) THEN u.sku ELSE t.sku END,
                unit_of_measure = CASE WHEN v_do_unit AND u.unit_of_measure IS NOT NULL THEN u.unit_of_measure ELSE t.unit_of_measure END,
                is_active = CASE WHEN v_do_is_active AND u.is_active IS NOT NULL THEN u.is_active ELSE t.is_active END,
                reorder_point = CASE WHEN v_do_reorder_point AND u.reorder_point IS NOT NULL THEN u.reorder_point ELSE t.reorder_point END,
                reorder_quantity = CASE WHEN v_do_reorder_qty AND u.reorder_quantity IS NOT NULL THEN u.reorder_quantity ELSE t.reorder_quantity END,
                reorder_enabled = CASE WHEN v_do_reorder_enabled AND u.reorder_enabled IS NOT NULL THEN u.reorder_enabled ELSE t.reorder_enabled END,
                category_id = CASE WHEN v_do_category AND u.category_id IS NOT NULL THEN u.category_id ELSE t.category_id END,
                location_id = CASE WHEN v_do_location AND u.location_id IS NOT NULL THEN u.location_id ELSE t.location_id END,
                updated_at = v_now
            FROM to_update u
            WHERE u.has_update
              AND t.id = u.id
            RETURNING t.id
        )
        SELECT COUNT(*) INTO v_items_updated FROM upd;
    END IF;

    INSERT INTO public.inventory_seed_runs (
        source_company_id,
        target_company_id,
        mode,
        dedupe_key,
        items_copied_count,
        items_updated_count,
        seed_fields,
        created_by,
        created_at
    ) VALUES (
        p_source_company_id,
        p_target_company_id,
        v_mode,
        v_dedupe_key,
        v_items_copied,
        v_items_updated,
        v_seed_fields,
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
            'seed_fields', v_seed_fields,
            'items_copied_count', v_items_copied,
            'items_updated_count', v_items_updated,
            'timestamp', v_now
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'seed_run_id', v_seed_run_id,
        'items_copied_count', v_items_copied,
        'items_updated_count', v_items_updated,
        'seed_fields', v_seed_fields,
        'mode', v_mode
    );
END;
$$;

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
BEGIN
    RETURN public.seed_company_inventory(
        p_source_company_id,
        p_target_company_id,
        p_mode,
        p_dedupe_key,
        NULL::text[]
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.seed_company_inventory(UUID, UUID, TEXT, TEXT, TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seed_company_inventory(UUID, UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_inventory_seed_status(
    p_target_company_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_items_seeded BOOLEAN := false;
    v_seeded_fields TEXT[] := ARRAY[]::text[];
    v_runs INTEGER := 0;
    v_last_seeded_at TIMESTAMPTZ;
    v_last_source UUID;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF p_target_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target company required');
    END IF;

    SELECT COUNT(*)
    INTO v_runs
    FROM public.inventory_seed_runs
    WHERE target_company_id = p_target_company_id;

    IF v_runs = 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'items_seeded', false,
            'seeded_fields', ARRAY[]::text[],
            'runs', 0
        );
    END IF;

    SELECT bool_or(coalesce(seed_fields, ARRAY['items']::text[]) @> ARRAY['items']::text[])
    INTO v_items_seeded
    FROM public.inventory_seed_runs
    WHERE target_company_id = p_target_company_id;

    SELECT array_agg(DISTINCT field ORDER BY field)
    INTO v_seeded_fields
    FROM public.inventory_seed_runs r
    CROSS JOIN LATERAL unnest(coalesce(r.seed_fields, ARRAY['items']::text[])) field
    WHERE r.target_company_id = p_target_company_id;

    SELECT
        (array_agg(source_company_id ORDER BY created_at DESC))[1],
        max(created_at)
    INTO v_last_source, v_last_seeded_at
    FROM public.inventory_seed_runs
    WHERE target_company_id = p_target_company_id;

    RETURN jsonb_build_object(
        'success', true,
        'items_seeded', COALESCE(v_items_seeded, false),
        'seeded_fields', COALESCE(v_seeded_fields, ARRAY[]::text[]),
        'runs', v_runs,
        'last_seeded_at', v_last_seeded_at,
        'last_source_company_id', v_last_source
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_inventory_seed_status(UUID) TO authenticated;

COMMIT;
