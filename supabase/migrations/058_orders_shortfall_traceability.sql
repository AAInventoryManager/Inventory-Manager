-- Phase 6: order traceability to job shortfalls

BEGIN;

ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS shortfall_id UUID;

ALTER TABLE public.orders
    DROP CONSTRAINT IF EXISTS orders_shortfall_id_fkey;
ALTER TABLE public.orders
    ADD CONSTRAINT orders_shortfall_id_fkey
    FOREIGN KEY (shortfall_id)
    REFERENCES public.shortfalls(shortfall_id)
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_orders_shortfall_id
    ON public.orders(shortfall_id)
    WHERE shortfall_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validate_orders_shortfall_company()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.shortfall_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.shortfalls s
            WHERE s.shortfall_id = NEW.shortfall_id
              AND s.company_id = NEW.company_id
        ) THEN
            RAISE EXCEPTION 'shortfall_id must belong to same company';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_orders_shortfall_company ON public.orders;
CREATE TRIGGER validate_orders_shortfall_company
    BEFORE INSERT OR UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.validate_orders_shortfall_company();

COMMIT;
