-- Add soft deduplication fields for inbound receipt ingestion.
ALTER TABLE public.receipts
  ADD COLUMN IF NOT EXISTS receipt_fingerprint TEXT,
  ADD COLUMN IF NOT EXISTS possible_duplicate BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS receipts_company_fingerprint_created_at_idx
  ON public.receipts (company_id, receipt_fingerprint, created_at DESC);
