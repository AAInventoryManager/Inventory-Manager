-- Migrate existing orders from legacy 'orders' table to 'purchase_orders' and 'purchase_order_items'
-- This ensures order history displays all orders correctly

BEGIN;

-- Insert orders into purchase_orders table (skip if already exists by po_number + company_id)
INSERT INTO public.purchase_orders (
    id,
    company_id,
    created_by,
    po_number,
    status,
    order_date,
    recipient_email,
    recipient_name,
    notes,
    email_subject,
    ship_to_location_id,
    related_job_numbers,
    created_at,
    updated_at
)
SELECT
    o.id,
    o.company_id,
    o.created_by,
    COALESCE(NULLIF(o.company_po_number, ''), NULLIF(o.internal_po_number, ''), 'LEGACY-' || LEFT(o.id::text, 8)),
    CASE
        WHEN o.received_at IS NOT NULL THEN 'received'
        WHEN o.receiving_at IS NOT NULL THEN 'partial'
        WHEN o.deleted_at IS NOT NULL THEN 'voided'
        ELSE 'submitted'
    END,
    o.created_at::date,
    o.to_email,
    o.contact_name,
    o.notes,
    o.subject,
    o.shipping_address_id,
    o.related_job_numbers,
    o.created_at,
    COALESCE(o.received_at, o.receiving_at, o.created_at)
FROM public.orders o
WHERE o.company_id IS NOT NULL
  AND o.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.purchase_orders po
    WHERE po.id = o.id
  )
ON CONFLICT (company_id, po_number) DO NOTHING;

-- Insert line items from orders.line_items JSONB into purchase_order_items
INSERT INTO public.purchase_order_items (
    purchase_order_id,
    item_id,
    item_name,
    item_sku,
    quantity_ordered,
    created_at
)
SELECT
    o.id,
    NULLIF(TRIM(item->>'item_id'), '')::uuid,
    COALESCE(NULLIF(TRIM(item->>'part'), ''), NULLIF(TRIM(item->>'name'), ''), 'Unknown Item'),
    NULLIF(TRIM(item->>'desc'), ''),
    COALESCE((item->>'qty')::integer, 0),
    o.created_at
FROM public.orders o,
     jsonb_array_elements(COALESCE(o.line_items, '[]'::jsonb)) AS item
WHERE o.company_id IS NOT NULL
  AND o.deleted_at IS NULL
  AND EXISTS (
    SELECT 1 FROM public.purchase_orders po WHERE po.id = o.id
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.purchase_order_items poi
    WHERE poi.purchase_order_id = o.id
  );

COMMIT;
