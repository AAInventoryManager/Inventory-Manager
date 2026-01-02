-- Purchase Order approval guardrail (MRP-lite)

BEGIN;

CREATE OR REPLACE FUNCTION public.approve_purchase_order(
    p_purchase_order_id UUID,
    p_target_status TEXT DEFAULT 'approved'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company_id UUID;
    v_status TEXT;
    v_target TEXT := lower(trim(p_target_status));
    v_line_table TEXT;
    v_violation JSONB;
BEGIN
    IF p_purchase_order_id IS NULL THEN
        RAISE EXCEPTION 'Missing purchase_order_id';
    END IF;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT company_id, status
    INTO v_company_id, v_status
    FROM public.purchase_orders
    WHERE id = p_purchase_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase order not found';
    END IF;

    IF NOT public.check_permission(v_company_id, 'orders:edit') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    IF v_status IN ('approved', 'submitted') THEN
        RETURN jsonb_build_object('success', true, 'status', v_status, 'idempotent', true);
    END IF;

    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'Purchase order cannot be approved from status %', v_status;
    END IF;

    IF v_target NOT IN ('approved', 'submitted') THEN
        RAISE EXCEPTION 'Invalid target status %', v_target;
    END IF;

    v_line_table := CASE
        WHEN to_regclass('public.purchase_order_lines') IS NOT NULL THEN 'purchase_order_lines'
        WHEN to_regclass('public.purchase_order_items') IS NOT NULL THEN 'purchase_order_items'
        ELSE NULL
    END;

    IF v_line_table IS NULL THEN
        RAISE EXCEPTION 'Purchase order lines table not found';
    END IF;

    EXECUTE format($sql$
        WITH lines AS (
            SELECT
                item_id,
                COALESCE(quantity_ordered, qty_ordered, ordered_qty, quantity, qty, 0) AS ordered_qty
            FROM public.%I
            WHERE purchase_order_id = $1
        ),
        items AS (
            SELECT DISTINCT item_id FROM lines WHERE item_id IS NOT NULL
        ),
        lock_items AS (
            SELECT 1
            FROM public.inventory_items i
            JOIN items t ON t.item_id = i.id
            WHERE i.company_id = $2
            FOR UPDATE
        ),
        job_totals AS (
            SELECT b.item_id, SUM(b.qty_planned) AS planned_qty
            FROM public.job_bom b
            JOIN public.jobs j ON j.id = b.job_id
            WHERE j.status = 'approved'
              AND j.company_id = $2
            GROUP BY b.item_id
        ),
        inv AS (
            SELECT i.id AS item_id, i.quantity AS on_hand
            FROM public.inventory_items i
            WHERE i.company_id = $2
              AND i.deleted_at IS NULL
        ),
        job_demand AS (
            SELECT
                items.item_id,
                GREATEST(COALESCE(job_totals.planned_qty, 0) - COALESCE(inv.on_hand, 0), 0) AS demand_qty
            FROM items
            LEFT JOIN job_totals ON job_totals.item_id = items.item_id
            LEFT JOIN inv ON inv.item_id = items.item_id
        ),
        incoming_supply AS (
            SELECT
                l.item_id,
                SUM(COALESCE(l.quantity_ordered, l.qty_ordered, l.ordered_qty, l.quantity, l.qty, 0)) AS supply_qty
            FROM public.%I l
            JOIN public.purchase_orders p ON p.id = l.purchase_order_id
            WHERE p.company_id = $2
              AND p.status IN ('approved', 'submitted')
              AND p.id <> $1
            GROUP BY l.item_id
        ),
        calc AS (
            SELECT
                lines.item_id,
                lines.ordered_qty,
                COALESCE(job_demand.demand_qty, 0) AS job_demand,
                COALESCE(incoming_supply.supply_qty, 0) AS incoming_supply,
                GREATEST(COALESCE(job_demand.demand_qty, 0) - COALESCE(incoming_supply.supply_qty, 0), 0) AS net_required
            FROM lines
            LEFT JOIN job_demand ON job_demand.item_id = lines.item_id
            LEFT JOIN incoming_supply ON incoming_supply.item_id = lines.item_id
            WHERE lines.item_id IS NOT NULL
        )
        SELECT jsonb_agg(jsonb_build_object(
            'item_id', item_id,
            'ordered_qty', ordered_qty,
            'job_demand', job_demand,
            'incoming_supply', incoming_supply,
            'net_required', net_required
        ))
        FROM calc
        WHERE ordered_qty > net_required;
    $sql$, v_line_table, v_line_table)
    INTO v_violation
    USING p_purchase_order_id, v_company_id;

    IF v_violation IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            MESSAGE = 'PO_EXCEEDS_JOB_DEMAND',
            DETAIL = v_violation::text;
    END IF;

    UPDATE public.purchase_orders
    SET status = v_target
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object('success', true, 'status', v_target);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_purchase_order(UUID, TEXT) TO authenticated;

COMMIT;
