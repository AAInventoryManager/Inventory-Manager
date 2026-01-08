-- Receipt attachments metadata + storage bucket

BEGIN;

CREATE TABLE IF NOT EXISTS public.receipt_attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id UUID NOT NULL REFERENCES public.receipts(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    file_name TEXT NOT NULL,
    content_type TEXT,
    byte_size INTEGER CHECK (byte_size >= 0),
    storage_provider TEXT NOT NULL DEFAULT 'supabase',
    storage_bucket TEXT,
    storage_path TEXT,
    storage_url TEXT,
    retention_expires_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES auth.users(id),
    CONSTRAINT receipt_attachments_provider_check
        CHECK (storage_provider IN ('supabase', 'external'))
);

COMMENT ON TABLE public.receipt_attachments IS
    'Stored receipt files and metadata for receipt ingestion.';

COMMENT ON COLUMN public.receipt_attachments.retention_expires_at IS
    'Retention deadline for stored receipt attachments.';

CREATE INDEX IF NOT EXISTS idx_receipt_attachments_receipt_id
    ON public.receipt_attachments(receipt_id);

CREATE INDEX IF NOT EXISTS idx_receipt_attachments_company_id
    ON public.receipt_attachments(company_id);

CREATE INDEX IF NOT EXISTS idx_receipt_attachments_retention
    ON public.receipt_attachments(retention_expires_at);

ALTER TABLE public.receipt_attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "receipt_attachments_select" ON public.receipt_attachments;
CREATE POLICY "receipt_attachments_select"
    ON public.receipt_attachments FOR SELECT
    TO authenticated
    USING (company_id IN (SELECT public.get_user_company_ids()));

DROP POLICY IF EXISTS "receipt_attachments_insert" ON public.receipt_attachments;
CREATE POLICY "receipt_attachments_insert"
    ON public.receipt_attachments FOR INSERT
    TO authenticated
    WITH CHECK (false);

DROP POLICY IF EXISTS "receipt_attachments_update" ON public.receipt_attachments;
CREATE POLICY "receipt_attachments_update"
    ON public.receipt_attachments FOR UPDATE
    TO authenticated
    USING (false)
    WITH CHECK (false);

DROP POLICY IF EXISTS "receipt_attachments_delete" ON public.receipt_attachments;
CREATE POLICY "receipt_attachments_delete"
    ON public.receipt_attachments FOR DELETE
    TO authenticated
    USING (false);

DROP TRIGGER IF EXISTS update_receipt_attachments_updated_at ON public.receipt_attachments;
CREATE TRIGGER update_receipt_attachments_updated_at
    BEFORE UPDATE ON public.receipt_attachments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

INSERT INTO storage.buckets (id, name, public)
VALUES ('receipt-attachments', 'receipt-attachments', false)
ON CONFLICT (id) DO NOTHING;

COMMIT;
