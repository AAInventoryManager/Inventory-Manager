# Changelog

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
