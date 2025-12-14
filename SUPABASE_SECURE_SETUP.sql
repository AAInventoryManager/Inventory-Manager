-- Inventory Manager (secure single-tenant) — Supabase setup
-- Run in Supabase SQL Editor.
-- This does NOT delete existing inventory rows.

-- =========================
-- 1) Profiles (per auth user)
-- =========================
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  first_name text not null default ''::text,
  last_name text not null default ''::text,
  phone text not null default ''::text,
  delivery_address text not null default ''::text,
  updated_at timestamp with time zone not null default now()
);

-- For older installs: add columns if missing
alter table public.profiles
  add column if not exists delivery_address text not null default ''::text;
alter table public.profiles
  add column if not exists first_name text not null default ''::text;
alter table public.profiles
  add column if not exists last_name text not null default ''::text;

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- Keep updated_at fresh
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- =========================
-- 2) Authorized users (who can access the shared inventory)
-- =========================
create table if not exists public.authorized_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'user',
  created_at timestamp with time zone not null default now()
);

alter table public.authorized_users enable row level security;

-- Allow users to read their own authorization row (used by RLS checks)
drop policy if exists "authorized_users_select_own" on public.authorized_users;
create policy "authorized_users_select_own"
on public.authorized_users for select
to authenticated
using (user_id = auth.uid());

-- Intentionally do NOT allow authenticated users to insert/update/delete rows here.
-- Manage `authorized_users` from the Supabase dashboard / SQL editor (service role).

-- =========================
-- 3) Order recipient autocomplete list (shared across authorized users)
-- =========================
create table if not exists public.order_recipients (
  email text primary key,
  name text,
  created_by uuid references auth.users(id) on delete set null,
  last_used_at timestamp with time zone not null default now(),
  created_at timestamp with time zone not null default now()
);

alter table public.order_recipients enable row level security;

drop policy if exists "order_recipients_authorized_all" on public.order_recipients;
create policy "order_recipients_authorized_all"
on public.order_recipients for all
to authenticated
using (
  exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
);

create index if not exists order_recipients_last_used_idx on public.order_recipients (last_used_at desc);

-- =========================
-- 4) Order history (per auth user)
-- =========================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  created_by uuid not null references auth.users(id) on delete cascade,
  to_email text not null,
  reply_to_email text not null default ''::text,
  subject text not null,
  contact_name text,
  notes text,
  line_items jsonb not null default '[]'::jsonb,
  provider text not null default 'mailtrap',
  provider_result jsonb
);

alter table public.orders enable row level security;

drop policy if exists "orders_select_own" on public.orders;
create policy "orders_select_own"
on public.orders for select
to authenticated
using (
  created_by = auth.uid()
  and exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
);

drop policy if exists "orders_insert_own" on public.orders;
create policy "orders_insert_own"
on public.orders for insert
to authenticated
with check (
  created_by = auth.uid()
  and exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
);

drop policy if exists "orders_delete_own" on public.orders;
create policy "orders_delete_own"
on public.orders for delete
to authenticated
using (
  created_by = auth.uid()
  and exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
);

create index if not exists orders_created_by_idx on public.orders (created_by);
create index if not exists orders_created_at_idx on public.orders (created_at desc);

-- =========================
-- 5) Lock down the existing `items` table (shared inventory)
-- =========================
alter table public.items enable row level security;

-- Remove old demo policies (safe to run even if they don't exist)
drop policy if exists "anon_read_items" on public.items;
drop policy if exists "anon_insert_items" on public.items;
drop policy if exists "anon_update_items" on public.items;
drop policy if exists "anon_delete_items" on public.items;

drop policy if exists "items_authorized_all" on public.items;
create policy "items_authorized_all"
on public.items for all
to authenticated
using (
  exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.authorized_users au
    where au.user_id = auth.uid()
  )
);

-- Done.
