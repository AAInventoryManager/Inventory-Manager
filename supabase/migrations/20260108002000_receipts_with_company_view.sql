-- Receipts inbox view with company context

BEGIN;

CREATE OR REPLACE VIEW public.receipts_with_company AS
SELECT
  r.id AS receipt_id,
  r.company_id,
  c.name AS company_name,
  c.slug AS company_slug,
  r.vendor_name,
  r.receipt_date,
  r.total,
  r.receipt_source,
  r.status,
  r.created_at
FROM public.receipts r
JOIN public.companies c ON c.id = r.company_id;

COMMIT;
