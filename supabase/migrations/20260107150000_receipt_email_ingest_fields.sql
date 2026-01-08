-- Add fields to store inbound email receipt data (draft-only ingestion)

BEGIN;

ALTER TABLE public.receipts
  ADD COLUMN IF NOT EXISTS receipt_source TEXT,
  ADD COLUMN IF NOT EXISTS vendor_name TEXT,
  ADD COLUMN IF NOT EXISTS receipt_date DATE,
  ADD COLUMN IF NOT EXISTS subtotal NUMERIC,
  ADD COLUMN IF NOT EXISTS tax NUMERIC,
  ADD COLUMN IF NOT EXISTS total NUMERIC,
  ADD COLUMN IF NOT EXISTS raw_receipt_text TEXT,
  ADD COLUMN IF NOT EXISTS parsed_line_items JSONB,
  ADD COLUMN IF NOT EXISTS email_metadata JSONB;

COMMIT;
