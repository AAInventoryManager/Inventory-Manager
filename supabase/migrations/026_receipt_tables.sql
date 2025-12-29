-- Receipt-based receiving tables (Inventory Receiving v2)

BEGIN;

CREATE TABLE IF NOT EXISTS public.receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    purchase_order_id UUID NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft','completed','voided')),
    received_by UUID NOT NULL REFERENCES auth.users(id),
    received_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.receipts IS
    'Receipt-based receiving records. Inventory impact occurs only on completion, and partial receiving is expected (multiple receipts may reference one PO).';

COMMENT ON COLUMN public.receipts.status IS
    'Lifecycle state; inventory impact occurs only when status = completed.';

CREATE INDEX IF NOT EXISTS idx_receipts_company_id
    ON public.receipts(company_id);

CREATE INDEX IF NOT EXISTS idx_receipts_purchase_order_id
    ON public.receipts(purchase_order_id);

CREATE INDEX IF NOT EXISTS idx_receipts_status
    ON public.receipts(status);

CREATE TABLE IF NOT EXISTS public.receipt_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id UUID NOT NULL REFERENCES public.receipts(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES public.inventory_items(id),
    qty_received NUMERIC NOT NULL CHECK (qty_received >= 0),
    qty_rejected NUMERIC NOT NULL DEFAULT 0 CHECK (qty_rejected >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.receipt_lines IS
    'Receipt lines capture factual quantities received (not planned). qty_received impacts inventory only on receipt completion; qty_rejected is informational.';

CREATE INDEX IF NOT EXISTS idx_receipt_lines_receipt_id
    ON public.receipt_lines(receipt_id);

CREATE INDEX IF NOT EXISTS idx_receipt_lines_item_id
    ON public.receipt_lines(item_id);

COMMIT;
