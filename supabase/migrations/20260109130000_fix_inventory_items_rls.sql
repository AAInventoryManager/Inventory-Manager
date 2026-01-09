-- Fix inventory_items RLS policies: remove overly permissive company-only policies
-- These were incorrectly added by the baseline migration and override the permission-based
-- policies from 010_phase1_inventory_enforcement.sql.
--
-- The original policies from 010 use check_permission() for proper role enforcement:
-- - "Users can view active inventory": items:view + deleted_at IS NULL
-- - "Admins can view deleted inventory": items:delete OR items:restore + deleted_at IS NOT NULL
-- - "Writers can create inventory": items:create
-- - "Writers can update inventory": items:edit

BEGIN;

-- Drop the overly permissive policies added by the baseline migration
DROP POLICY IF EXISTS "inventory_items_company_read" ON public.inventory_items;
DROP POLICY IF EXISTS "inventory_items_company_insert" ON public.inventory_items;
DROP POLICY IF EXISTS "inventory_items_company_update" ON public.inventory_items;
DROP POLICY IF EXISTS "inventory_items_company_delete" ON public.inventory_items;

COMMIT;
