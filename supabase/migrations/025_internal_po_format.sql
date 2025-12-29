-- Update internal PO number format to 4 digits + 4 letters (no ambiguous letters).

BEGIN;

CREATE OR REPLACE FUNCTION public.generate_internal_po_number()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
    letters TEXT := 'ABCDEFGHJKMNPQRSTVWXYZ';
    digit_part TEXT := lpad((floor(random() * 10000))::int::text, 4, '0');
    letter_part TEXT := '';
    i INTEGER;
BEGIN
    FOR i IN 1..4 LOOP
        letter_part := letter_part || substr(letters, floor(random() * length(letters))::int + 1, 1);
    END LOOP;
    RETURN digit_part || '-' || letter_part;
END;
$$;

ALTER TABLE public.orders
    ALTER COLUMN internal_po_number SET DEFAULT public.generate_internal_po_number();

COMMIT;
