-- Legacy baseline tables for local development and migration compatibility.
-- Safe to run against existing databases (all statements are IF NOT EXISTS).

BEGIN;

CREATE TABLE IF NOT EXISTS public.profiles (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    first_name TEXT NOT NULL DEFAULT ''::text,
    last_name TEXT NOT NULL DEFAULT ''::text,
    phone TEXT NOT NULL DEFAULT ''::text,
    delivery_address TEXT NOT NULL DEFAULT ''::text,
    low_stock_qty_global INTEGER NOT NULL DEFAULT 0,
    silence_low_stock_alerts BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.authorized_users (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.order_recipients (
    email TEXT PRIMARY KEY,
    name TEXT,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    to_email TEXT NOT NULL,
    reply_to_email TEXT NOT NULL DEFAULT ''::text,
    subject TEXT NOT NULL,
    contact_name TEXT,
    notes TEXT,
    line_items JSONB NOT NULL DEFAULT '[]'::jsonb,
    provider TEXT NOT NULL DEFAULT 'mailtrap',
    provider_result JSONB,
    receiving_at TIMESTAMPTZ,
    receiving_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    receiving_snapshot JSONB,
    received_at TIMESTAMPTZ,
    received_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    received_snapshot JSONB,
    received_undone_at TIMESTAMPTZ,
    received_undone_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT DEFAULT ''::text,
    qty INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    low_stock_qty INTEGER,
    reorder_enabled BOOLEAN NOT NULL DEFAULT true
);

CREATE UNIQUE INDEX IF NOT EXISTS items_name_ci_unique ON public.items (lower(name));
CREATE INDEX IF NOT EXISTS order_recipients_last_used_idx ON public.order_recipients (last_used_at DESC);
CREATE INDEX IF NOT EXISTS orders_created_by_idx ON public.orders (created_by);
CREATE INDEX IF NOT EXISTS orders_created_at_idx ON public.orders (created_at DESC);

COMMIT;
