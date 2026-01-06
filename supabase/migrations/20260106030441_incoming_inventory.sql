-- Incoming inventory derived from submitted purchase orders

BEGIN;

CREATE TABLE IF NOT EXISTS public.incoming_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    po_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
    qty_ordered INTEGER NOT NULL CHECK (qty_ordered > 0),
    status TEXT NOT NULL DEFAULT 'ordered' CHECK (status IN ('ordered','shipped','received','cancelled')),
    expected_date DATE NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_incoming_inventory_company_id
    ON public.incoming_inventory(company_id);

CREATE INDEX IF NOT EXISTS idx_incoming_inventory_item_id
    ON public.incoming_inventory(item_id);

CREATE INDEX IF NOT EXISTS idx_incoming_inventory_company_item
    ON public.incoming_inventory(company_id, item_id);

CREATE INDEX IF NOT EXISTS idx_incoming_inventory_status
    ON public.incoming_inventory(status);

ALTER TABLE public.incoming_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "incoming_inventory_select" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_select"
    ON public.incoming_inventory FOR SELECT
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "incoming_inventory_insert" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_insert"
    ON public.incoming_inventory FOR INSERT
    TO authenticated
    WITH CHECK (false);

DROP POLICY IF EXISTS "incoming_inventory_update" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_update"
    ON public.incoming_inventory FOR UPDATE
    TO authenticated
    USING (false)
    WITH CHECK (false);

DROP POLICY IF EXISTS "incoming_inventory_delete" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_delete"
    ON public.incoming_inventory FOR DELETE
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

CREATE OR REPLACE VIEW public.inventory_incoming_by_item AS
SELECT
    company_id,
    item_id,
    SUM(qty_ordered) AS incoming_qty
FROM public.incoming_inventory
WHERE status IN ('ordered','shipped')
GROUP BY company_id, item_id;

COMMIT;
