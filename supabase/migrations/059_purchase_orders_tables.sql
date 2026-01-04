-- Create purchase_orders and purchase_order_items tables
-- These tables support the Order History functionality

BEGIN;

-- Purchase orders table
CREATE TABLE IF NOT EXISTS public.purchase_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    vendor_id UUID, -- No FK constraint - vendors table may not exist
    vendor_name TEXT, -- Denormalized vendor name for display

    -- PO identification
    po_number TEXT NOT NULL,

    -- Status tracking
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'sent', 'submitted', 'approved', 'confirmed', 'partial', 'received', 'cancelled', 'voided')),

    -- Dates
    order_date DATE DEFAULT CURRENT_DATE,
    expected_date DATE,
    received_date DATE,

    -- Delivery info
    ship_to_location_id UUID REFERENCES public.company_locations(id),
    recipient_email TEXT,
    recipient_name TEXT,

    -- Totals (calculated)
    subtotal DECIMAL(10,2) DEFAULT 0,
    tax DECIMAL(10,2) DEFAULT 0,
    shipping DECIMAL(10,2) DEFAULT 0,
    total DECIMAL(10,2) DEFAULT 0,

    -- Notes
    notes TEXT,
    vendor_notes TEXT,

    -- Email content (for history)
    email_subject TEXT,
    email_body TEXT,

    -- Metadata
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),

    UNIQUE(company_id, po_number)
);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_company ON public.purchase_orders(company_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_status ON public.purchase_orders(company_id, status);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_order_date ON public.purchase_orders(company_id, order_date DESC);

-- Purchase order line items
CREATE TABLE IF NOT EXISTS public.purchase_order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
    item_id UUID REFERENCES public.inventory_items(id),

    -- Item details (denormalized for historical record)
    item_name TEXT NOT NULL,
    item_sku TEXT,

    -- Quantities
    quantity_ordered INTEGER NOT NULL,
    quantity_received INTEGER DEFAULT 0,

    -- Pricing
    unit_cost DECIMAL(10,2) DEFAULT 0,
    line_total DECIMAL(10,2) GENERATED ALWAYS AS (quantity_ordered * unit_cost) STORED,

    -- Notes
    notes TEXT,

    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_po_items_order ON public.purchase_order_items(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_po_items_item ON public.purchase_order_items(item_id);

-- Enable RLS
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;

-- RLS policies for purchase_orders
DROP POLICY IF EXISTS "purchase_orders_select" ON public.purchase_orders;
CREATE POLICY "purchase_orders_select"
    ON public.purchase_orders FOR SELECT
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "purchase_orders_insert" ON public.purchase_orders;
CREATE POLICY "purchase_orders_insert"
    ON public.purchase_orders FOR INSERT
    TO authenticated
    WITH CHECK (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:create')
    );

DROP POLICY IF EXISTS "purchase_orders_update" ON public.purchase_orders;
CREATE POLICY "purchase_orders_update"
    ON public.purchase_orders FOR UPDATE
    TO authenticated
    USING (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:edit')
    );

DROP POLICY IF EXISTS "purchase_orders_delete" ON public.purchase_orders;
CREATE POLICY "purchase_orders_delete"
    ON public.purchase_orders FOR DELETE
    TO authenticated
    USING (
        company_id IN (SELECT public.get_user_company_ids())
        AND public.check_permission(company_id, 'orders:delete')
    );

-- RLS policies for purchase_order_items
DROP POLICY IF EXISTS "po_items_select" ON public.purchase_order_items;
CREATE POLICY "po_items_select"
    ON public.purchase_order_items FOR SELECT
    TO authenticated
    USING (
        purchase_order_id IN (
            SELECT id FROM public.purchase_orders
            WHERE company_id IN (SELECT public.get_user_company_ids())
        )
    );

DROP POLICY IF EXISTS "po_items_insert" ON public.purchase_order_items;
CREATE POLICY "po_items_insert"
    ON public.purchase_order_items FOR INSERT
    TO authenticated
    WITH CHECK (
        purchase_order_id IN (
            SELECT id FROM public.purchase_orders
            WHERE company_id IN (SELECT public.get_user_company_ids())
            AND public.check_permission(company_id, 'orders:create')
        )
    );

DROP POLICY IF EXISTS "po_items_update" ON public.purchase_order_items;
CREATE POLICY "po_items_update"
    ON public.purchase_order_items FOR UPDATE
    TO authenticated
    USING (
        purchase_order_id IN (
            SELECT id FROM public.purchase_orders
            WHERE company_id IN (SELECT public.get_user_company_ids())
            AND public.check_permission(company_id, 'orders:edit')
        )
    );

DROP POLICY IF EXISTS "po_items_delete" ON public.purchase_order_items;
CREATE POLICY "po_items_delete"
    ON public.purchase_order_items FOR DELETE
    TO authenticated
    USING (
        purchase_order_id IN (
            SELECT id FROM public.purchase_orders
            WHERE company_id IN (SELECT public.get_user_company_ids())
            AND public.check_permission(company_id, 'orders:delete')
        )
    );

-- Updated_at trigger
CREATE OR REPLACE FUNCTION public.update_purchase_order_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS purchase_orders_updated_at ON public.purchase_orders;
CREATE TRIGGER purchase_orders_updated_at
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW
    EXECUTE FUNCTION public.update_purchase_order_updated_at();

COMMIT;
