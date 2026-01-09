-- Baseline company-scoped RLS policies for core operational tables.

BEGIN;

-- Companies: members can view and update their companies.
DROP POLICY IF EXISTS "companies_read" ON public.companies;
CREATE POLICY "companies_read"
ON public.companies
FOR SELECT
USING (
  id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "companies_write" ON public.companies;
CREATE POLICY "companies_write"
ON public.companies
FOR UPDATE
USING (
  id IN (SELECT public.get_user_company_ids())
);

-- Receipts: company-scoped access plus system ingestion inserts.
ALTER TABLE public.receipts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "receipts_company_read" ON public.receipts;
CREATE POLICY "receipts_company_read"
ON public.receipts
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "receipts_company_insert" ON public.receipts;
CREATE POLICY "receipts_company_insert"
ON public.receipts
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "receipts_company_update" ON public.receipts;
CREATE POLICY "receipts_company_update"
ON public.receipts
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "receipts_company_delete" ON public.receipts;
CREATE POLICY "receipts_company_delete"
ON public.receipts
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "receipts_system_ingest" ON public.receipts;
CREATE POLICY "receipts_system_ingest"
ON public.receipts
FOR INSERT
WITH CHECK (
  auth.uid() = '0d138ecc-fdca-47aa-af9f-712e091db791'
);

-- Inventory items.
DROP POLICY IF EXISTS "inventory_items_company_read" ON public.inventory_items;
CREATE POLICY "inventory_items_company_read"
ON public.inventory_items
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "inventory_items_company_insert" ON public.inventory_items;
CREATE POLICY "inventory_items_company_insert"
ON public.inventory_items
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "inventory_items_company_update" ON public.inventory_items;
CREATE POLICY "inventory_items_company_update"
ON public.inventory_items
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "inventory_items_company_delete" ON public.inventory_items;
CREATE POLICY "inventory_items_company_delete"
ON public.inventory_items
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

-- Incoming inventory.
DROP POLICY IF EXISTS "incoming_inventory_company_read" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_company_read"
ON public.incoming_inventory
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "incoming_inventory_company_insert" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_company_insert"
ON public.incoming_inventory
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "incoming_inventory_company_update" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_company_update"
ON public.incoming_inventory
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "incoming_inventory_company_delete" ON public.incoming_inventory;
CREATE POLICY "incoming_inventory_company_delete"
ON public.incoming_inventory
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

-- Purchase orders.
DROP POLICY IF EXISTS "purchase_orders_company_read" ON public.purchase_orders;
CREATE POLICY "purchase_orders_company_read"
ON public.purchase_orders
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "purchase_orders_company_insert" ON public.purchase_orders;
CREATE POLICY "purchase_orders_company_insert"
ON public.purchase_orders
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "purchase_orders_company_update" ON public.purchase_orders;
CREATE POLICY "purchase_orders_company_update"
ON public.purchase_orders
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "purchase_orders_company_delete" ON public.purchase_orders;
CREATE POLICY "purchase_orders_company_delete"
ON public.purchase_orders
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

-- Jobs.
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "jobs_company_read" ON public.jobs;
CREATE POLICY "jobs_company_read"
ON public.jobs
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "jobs_company_insert" ON public.jobs;
CREATE POLICY "jobs_company_insert"
ON public.jobs
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "jobs_company_update" ON public.jobs;
CREATE POLICY "jobs_company_update"
ON public.jobs
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "jobs_company_delete" ON public.jobs;
CREATE POLICY "jobs_company_delete"
ON public.jobs
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

-- Job item allocations.
DROP POLICY IF EXISTS "job_item_allocations_company_read" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_company_read"
ON public.job_item_allocations
FOR SELECT
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "job_item_allocations_company_insert" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_company_insert"
ON public.job_item_allocations
FOR INSERT
WITH CHECK (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "job_item_allocations_company_update" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_company_update"
ON public.job_item_allocations
FOR UPDATE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

DROP POLICY IF EXISTS "job_item_allocations_company_delete" ON public.job_item_allocations;
CREATE POLICY "job_item_allocations_company_delete"
ON public.job_item_allocations
FOR DELETE
USING (
  company_id IN (SELECT public.get_user_company_ids())
);

-- Inventory adjustments (append-only) if present.
DO $$
BEGIN
  IF to_regclass('public.inventory_adjustments') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.inventory_adjustments ENABLE ROW LEVEL SECURITY';

    EXECUTE 'DROP POLICY IF EXISTS "inventory_adjustments_company_read" ON public.inventory_adjustments';
    EXECUTE '' ||
      'CREATE POLICY "inventory_adjustments_company_read" ' ||
      'ON public.inventory_adjustments FOR SELECT ' ||
      'USING (company_id IN (SELECT public.get_user_company_ids()))';

    EXECUTE 'DROP POLICY IF EXISTS "inventory_adjustments_company_insert" ON public.inventory_adjustments';
    EXECUTE '' ||
      'CREATE POLICY "inventory_adjustments_company_insert" ' ||
      'ON public.inventory_adjustments FOR INSERT ' ||
      'WITH CHECK (company_id IN (SELECT public.get_user_company_ids()))';
  END IF;
END $$;

-- Purchase order lines (if present).
DO $$
BEGIN
  IF to_regclass('public.purchase_order_lines') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY';

    EXECUTE 'DROP POLICY IF EXISTS "purchase_order_lines_company_read" ON public.purchase_order_lines';
    EXECUTE '' ||
      'CREATE POLICY "purchase_order_lines_company_read" ' ||
      'ON public.purchase_order_lines FOR SELECT ' ||
      'USING (company_id IN (SELECT public.get_user_company_ids()))';

    EXECUTE 'DROP POLICY IF EXISTS "purchase_order_lines_company_insert" ON public.purchase_order_lines';
    EXECUTE '' ||
      'CREATE POLICY "purchase_order_lines_company_insert" ' ||
      'ON public.purchase_order_lines FOR INSERT ' ||
      'WITH CHECK (company_id IN (SELECT public.get_user_company_ids()))';

    EXECUTE 'DROP POLICY IF EXISTS "purchase_order_lines_company_update" ON public.purchase_order_lines';
    EXECUTE '' ||
      'CREATE POLICY "purchase_order_lines_company_update" ' ||
      'ON public.purchase_order_lines FOR UPDATE ' ||
      'USING (company_id IN (SELECT public.get_user_company_ids()))';

    EXECUTE 'DROP POLICY IF EXISTS "purchase_order_lines_company_delete" ON public.purchase_order_lines';
    EXECUTE '' ||
      'CREATE POLICY "purchase_order_lines_company_delete" ' ||
      'ON public.purchase_order_lines FOR DELETE ' ||
      'USING (company_id IN (SELECT public.get_user_company_ids()))';
  END IF;
END $$;

COMMIT;
