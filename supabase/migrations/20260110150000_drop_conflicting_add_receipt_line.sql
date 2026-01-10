-- Drop conflicting add_receipt_line overload from 20260109150000_fix_po_lines_table_reference.sql
-- That migration created a function with signature (UUID, UUID, UUID, INTEGER, INTEGER, INTEGER, TEXT)
-- which conflicts with the canonical signature in 20260210120000_fix_receipt_po_line_table.sql
-- PostgREST cannot disambiguate between the two overloads, causing PGRST203 errors

DROP FUNCTION IF EXISTS public.add_receipt_line(UUID, UUID, UUID, INTEGER, INTEGER, INTEGER, TEXT);
