-- Inventory seeding run tracking (append-only metadata)
-- Feature IDs: inventory.seeding.super_user

BEGIN;

CREATE TABLE IF NOT EXISTS public.inventory_seed_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_company_id UUID NOT NULL,
    target_company_id UUID NOT NULL,
    mode TEXT NOT NULL,
    dedupe_key TEXT NOT NULL,
    items_copied_count INTEGER NOT NULL DEFAULT 0,
    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT inventory_seed_runs_source_target_check
        CHECK (source_company_id <> target_company_id),
    CONSTRAINT inventory_seed_runs_mode_check
        CHECK (mode IN ('items_only')),
    CONSTRAINT inventory_seed_runs_dedupe_key_check
        CHECK (dedupe_key IN ('sku','name')),
    CONSTRAINT inventory_seed_runs_target_company_unique
        UNIQUE (target_company_id)
);

COMMENT ON TABLE public.inventory_seed_runs IS
    'Append-only record of inventory seeding runs; no inventory data stored here and rows are never updated or deleted. Inventory items are copied by RPC logic.';

CREATE INDEX IF NOT EXISTS idx_inventory_seed_runs_source_company_id
    ON public.inventory_seed_runs(source_company_id);

CREATE INDEX IF NOT EXISTS idx_inventory_seed_runs_created_at
    ON public.inventory_seed_runs(created_at);

COMMIT;
