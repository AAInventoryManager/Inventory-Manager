-- Expand purchase_orders status check to cover receiving semantics without breaking legacy values.

BEGIN;

ALTER TABLE public.purchase_orders
  DROP CONSTRAINT IF EXISTS purchase_orders_status_check;

ALTER TABLE public.purchase_orders
  ADD CONSTRAINT purchase_orders_status_check
  CHECK (
    status IN (
      'draft',
      'sent',
      'submitted',
      'approved',
      'confirmed',
      'partial',
      'partially_received',
      'received',
      'fully_received',
      'cancelled',
      'closed',
      'voided'
    )
  ) NOT VALID;

ALTER TABLE public.purchase_orders
  VALIDATE CONSTRAINT purchase_orders_status_check;

COMMIT;
