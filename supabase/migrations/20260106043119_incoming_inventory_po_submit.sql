-- Create incoming inventory rows when a PO is submitted

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_incoming_inventory_on_po_submit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_line_table TEXT;
BEGIN
    IF NEW.status IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.status = 'submitted' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
        IF EXISTS (
            SELECT 1
            FROM public.incoming_inventory
            WHERE po_id = NEW.id
        ) THEN
            RETURN NEW;
        END IF;

        v_line_table := CASE
            WHEN to_regclass('public.purchase_order_lines') IS NOT NULL THEN 'purchase_order_lines'
            WHEN to_regclass('public.purchase_order_items') IS NOT NULL THEN 'purchase_order_items'
            ELSE NULL
        END;

        IF v_line_table IS NULL THEN
            RETURN NEW;
        END IF;

        EXECUTE format($sql$
            INSERT INTO public.incoming_inventory (
                company_id,
                po_id,
                item_id,
                qty_ordered,
                expected_date
            )
            SELECT
                $1::uuid AS company_id,
                $2::uuid AS po_id,
                l.item_id,
                GREATEST(
                    COALESCE(
                        l.quantity_ordered,
                        l.qty_ordered,
                        l.ordered_qty,
                        l.quantity,
                        l.qty,
                        0
                    ),
                    0
                ) AS qty_ordered,
                $3::date AS expected_date
            FROM public.%I l
            WHERE l.purchase_order_id = $2
              AND l.item_id IS NOT NULL
              AND GREATEST(
                    COALESCE(
                        l.quantity_ordered,
                        l.qty_ordered,
                        l.ordered_qty,
                        l.quantity,
                        l.qty,
                        0
                    ),
                    0
                  ) > 0
        $sql$, v_line_table)
        USING NEW.company_id, NEW.id, NEW.expected_date;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS purchase_orders_incoming_inventory ON public.purchase_orders;
CREATE TRIGGER purchase_orders_incoming_inventory
AFTER UPDATE OF status ON public.purchase_orders
FOR EACH ROW
EXECUTE FUNCTION public.handle_incoming_inventory_on_po_submit();

COMMIT;
