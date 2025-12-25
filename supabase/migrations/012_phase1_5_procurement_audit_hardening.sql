-- Phase 1.5 Extension: procurement email + audit log hardening
-- Feature IDs: inventory.orders.cart, inventory.orders.email_send, inventory.orders.history, inventory.audit.log

BEGIN;

-- Company-managed shipping addresses
CREATE TABLE IF NOT EXISTS public.company_shipping_addresses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    address TEXT NOT NULL,
    is_default BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES auth.users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_shipping_addresses_company
    ON public.company_shipping_addresses(company_id);
CREATE INDEX IF NOT EXISTS idx_shipping_addresses_default
    ON public.company_shipping_addresses(company_id)
    WHERE is_default = true;

ALTER TABLE public.company_shipping_addresses ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.company_shipping_addresses FROM anon, authenticated;
REVOKE ALL ON TABLE public.company_shipping_addresses FROM public;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.company_shipping_addresses TO authenticated;

DROP POLICY IF EXISTS "Users can view shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Users can view shipping addresses"
    ON public.company_shipping_addresses FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:view')
    );

DROP POLICY IF EXISTS "Managers can insert shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can insert shipping addresses"
    ON public.company_shipping_addresses FOR INSERT
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

DROP POLICY IF EXISTS "Managers can update shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can update shipping addresses"
    ON public.company_shipping_addresses FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    )
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

DROP POLICY IF EXISTS "Managers can delete shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can delete shipping addresses"
    ON public.company_shipping_addresses FOR DELETE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

-- Add update timestamp + company_id protection
DROP TRIGGER IF EXISTS update_company_shipping_addresses_updated_at ON public.company_shipping_addresses;
CREATE TRIGGER update_company_shipping_addresses_updated_at
    BEFORE UPDATE ON public.company_shipping_addresses
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS protect_company_shipping_addresses ON public.company_shipping_addresses;
CREATE TRIGGER protect_company_shipping_addresses
    BEFORE UPDATE ON public.company_shipping_addresses
    FOR EACH ROW EXECUTE FUNCTION public.protect_company_id();

-- Purchase order identifiers + shipping address snapshot on orders
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS internal_po_number TEXT,
    ADD COLUMN IF NOT EXISTS company_po_number TEXT,
    ADD COLUMN IF NOT EXISTS shipping_address_id UUID REFERENCES public.company_shipping_addresses(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS shipping_address_snapshot JSONB;

ALTER TABLE public.orders
    ALTER COLUMN internal_po_number SET DEFAULT concat('PO-', upper(substr(gen_random_uuid()::text, 1, 8)));

UPDATE public.orders
SET internal_po_number = COALESCE(internal_po_number, concat('PO-', upper(substr(gen_random_uuid()::text, 1, 8))))
WHERE internal_po_number IS NULL;

ALTER TABLE public.orders
    ALTER COLUMN internal_po_number SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_internal_po_company
    ON public.orders(company_id, internal_po_number);

CREATE INDEX IF NOT EXISTS idx_orders_company_po_number
    ON public.orders(company_id, company_po_number);

CREATE OR REPLACE FUNCTION public.protect_order_internal_po_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.internal_po_number IS DISTINCT FROM NEW.internal_po_number THEN
        RAISE EXCEPTION 'Cannot change internal_po_number';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_order_internal_po_number ON public.orders;
CREATE TRIGGER protect_order_internal_po_number
    BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.protect_order_internal_po_number();

-- Add shipping address permission to role configurations (defaults)
UPDATE public.role_configurations
SET permissions = CASE
    WHEN role_name = 'admin' AND NOT (COALESCE(permissions, '{}'::jsonb) ? 'orders:manage_shipping')
        THEN jsonb_set(COALESCE(permissions, '{}'::jsonb), '{orders:manage_shipping}', 'true'::jsonb, true)
    WHEN role_name IN ('member','viewer') AND NOT (COALESCE(permissions, '{}'::jsonb) ? 'orders:manage_shipping')
        THEN jsonb_set(COALESCE(permissions, '{}'::jsonb), '{orders:manage_shipping}', 'false'::jsonb, true)
    ELSE permissions
END,
    updated_at = now()
WHERE role_name IN ('admin','member','viewer');

COMMIT;
