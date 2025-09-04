# Changelog

## v1.0.2 — UI polish, sorting, PWA
- Header alignment: title/status left, logo right; constrained to table width
- Title styling: larger, bolder NASA-like font (Barlow)
- Sortable columns: Item/Description/Qty with persistent sort and arrows
- Description column: dynamic width on desktop, wraps on mobile
- Status text: embedded version + uppercase state; pill removed
- PWA: added icons (192/512), bumped SW cache to v14; manifest v4

## v1.0.1 — Server-first UI and connectivity
- Server-only rendering: snapshot load + realtime; no local item copies
- Offline edits blocked; status banner shows Connected/Offline
- Server-first Add/Edit/Delete/Import with post-refresh from server
- Service worker cache bumped to v12; manifest cache param v3
- Manifest tweaks: start_url './', short_name "Don's Inv", version 1.0.1

## v1.0.0 — Initial stable release
- iOS-friendly, offline-capable inventory tracker
- Supabase sync (items: id, name, description, qty) with realtime updates
- Import: file (CSV/TSV/TXT/JSON/XLSX/DOCX) + paste modal with preview
- Inline editing (Enter=save, Esc=cancel), live filter, bulk delete, CSV export
- PWA: manifest + service worker (immediate takeover), cache v9
- Multi-step Undo (last 5 ops), empty-state UI, basic error logging
