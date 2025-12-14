# Don's Inventory Tracker

## What's New
- v1.0.2: UI polish, column sorting with arrows, dynamic Description sizing, status text with version, PWA icons/cache bump.
  See full changelog: [CHANGELOG.md](./CHANGELOG.md).


A lightweight, mobile‑friendly inventory app that runs entirely in the browser. It supports inline editing, easy import/export, and real‑time cloud sync via Supabase.

![screenshot](./screenshot.png)

---

## ✨ Features

- **Editing**: Tap any cell (Item, Description, Qty). Desktop edits inline (`Enter` saves, `Esc` cancels); mobile opens a larger editor modal + has `+/-` Qty buttons for quick changes.
- **Real‑time sync**: Edits, adds, and deletes propagate instantly across devices via Supabase realtime.
- **Import / Paste data**:
  - Upload CSV, TSV, TXT, JSON, XLSX, XLS, DOCX, DOC, or PDF files.
  - Bulk‑paste tables from Excel, Word, or other sources with a preview step.
- **Export**: One‑click export of the current inventory as a clean CSV file.
- **Multi‑select delete**: Select rows with checkboxes and delete multiple items at once.
- **Filter**: Live search by name, description, or quantity.
- **Mobile optimized**:
  - Large touch targets and keyboard‑aware scrolling for inline edits.
  - Works great in Safari/Chrome on iOS and Android.
- **PWA support**: Installable, offline read‑only view, and a service worker with network‑first for HTML so updates appear quickly.

---

## 🚀 Getting Started

### Prerequisites

- A Supabase project (free tier works fine)
- Git + a static web server for local development (examples below)

### 1) Clone

```bash
git clone https://github.com/<your-org-or-username>/Inventory-Manager.git
cd Inventory-Manager
```

### 2) Configure Supabase

In `index.html`, set your Supabase credentials near the top:

```html
<script>
  window.SB_URL  = "https://YOUR-PROJECT.supabase.co";
  window.SB_ANON = "YOUR-ANON-PUBLIC-KEY";
</script>
```

Create the `items` table and indexes (SQL can be run in the Supabase SQL editor):

```sql
-- Enable extension if needed (often already enabled in Supabase)
-- create extension if not exists pgcrypto;

create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text default ''::text,
  qty integer not null default 0,
  updated_at timestamp with time zone not null default now()
);

-- Case‑insensitive uniqueness on name
create unique index if not exists items_name_ci_unique on public.items (lower(name));
```

### Secure Supabase setup (recommended)

This app now supports Supabase Auth + profiles + an authorization allow‑list so only approved users can read/write the shared inventory.

1) In the Supabase SQL editor, run `SUPABASE_SECURE_SETUP.sql`.

2) Create/sign up a user (Supabase Dashboard → **Authentication → Users**).

3) Add that user to the allow‑list:

```sql
insert into public.authorized_users (user_id, role)
values ('PASTE-USER-UUID-HERE', 'admin')
on conflict (user_id) do nothing;
```

Notes:

- This does **not** delete your existing `items` rows.
- `SUPABASE_SECURE_SETUP.sql` also creates `orders` (order history) and `order_recipients` (email autocomplete) tables.
- If you ran an older version of the SQL, it’s safe to re-run it to add new tables/policies.
- For best security, disable public signups and invite/create users from the dashboard.

### 3) Run locally

This is a static site. Serve the folder with any static server so the service worker works correctly.

Examples:

```bash
# Python 3
python3 -m http.server 5173

# Node http-server (npm i -g http-server)
http-server -p 5173
```

Then open:

```
http://localhost:5173/
```

### 3a) (Optional) Send orders via Mailtrap (no `mailto:`)

The Order Engine can send emails directly via a tiny local Node server (keeps your Mailtrap token off the client).

1) Create `.env`:

```bash
cp .env.example .env
```

2) Edit `.env` and set:

- `MAILTRAP_API_TOKEN`
- `MAILTRAP_FROM_EMAIL` (the “From” address)

3) Run the dev server (static + API):

```bash
node dev-server.mjs --port 5173
```

Then open `http://127.0.0.1:5173/` and use **Create Order → Submit Order**.

Notes:

- Some mobile browsers support contact picking (Chrome Android). If unavailable, type/paste the email.
- If you host the API elsewhere, set `window.ORDER_API_URL` in `index.html` to that endpoint.

### 4) Deploy

Any static hosting works (GitHub Pages, Netlify, Vercel, Cloudflare Pages, S3, etc.). Just publish the repository root.

Notes:

- The service worker is configured network‑first for HTML navigations and cache‑first for static assets.
- The app will show a connection banner: “Server Status = Connected” when Supabase is reachable, otherwise “Offline – Edits cannot be made until Connected”.
- All edits are server‑first; the table re‑renders from the server snapshot and realtime updates.

---

## 🧭 Usage Tips

- Tap a cell to edit. `Enter` saves, `Esc` cancels.
- Import supports PDF (best with digital text‑based PDFs). For best results, use CSV/XLSX.
- “Total Qty” above the table shows the sum of the currently displayed rows (respects the filter).

---

## 🛠 Development Notes

- Single‑file app: most logic lives in `index.html`.
- Service worker: `sw.js` pre‑caches core assets and bypasses cross‑origin requests (Supabase) so API responses are always fresh.
- Manifest: `manifest.webmanifest` has PWA metadata and icons.

---

## 📄 License

Copyright © 2025. All rights reserved.



## Releases
- Latest: [v1.0.2](https://github.com/AAInventoryManager/Inventory-Manager/releases/latest)
- All releases: https://github.com/AAInventoryManager/Inventory-Manager/releases
