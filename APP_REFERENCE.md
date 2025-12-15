# Inventory Manager — App Reference

This repository is a single‑page web app (mostly in `index.html`) for managing an inventory, generating low‑stock reports, and building/sending material orders. This document describes the UI layout, features, modals, and the major event listeners/behaviors.

## Architecture at a glance

- **Single‑file app**: UI markup + CSS + JS live in `index.html`.
- **Server‑first inventory**: inventory items are loaded from Supabase and kept in memory (`state.items`). The app intentionally does **not** persist items in localStorage.
- **Auth + authorization**: users sign in via Supabase Auth; access is gated by an `authorized_users` table.
- **Realtime sync**: changes to the `items` table are subscribed via Supabase Realtime and reflected in `state.items`.
- **PWA**: `manifest.webmanifest` + `sw.js` provide installability and offline caching (offline is read‑only).

## Core state & helpers

### In‑memory state (`state`)

`state` is the app’s in‑memory store (defined near the top of the `<script>`):

- `state.items`: array of item objects (loaded from Supabase).
- `state.updatedAt`: ISO timestamp used for “Last Update” UI.
- `state._filter`: current inventory filter string.
- `state._sort`: `{ col, dir }` sort state (desktop header + mobile select).
- `state._order`: order‑builder state `{ lines, email, subject, notes, contactName, search }`.
- Additional transient fields are created during flows (e.g. `state._pendingImport`, history caches).

### Local persistence (UI prefs only)

- localStorage key: `inv.single.inline.mobile.v1`
- persisted fields: `updatedAt`, `_filter`, `_sort`
- **never persisted**: `state.items`

### Formatting and validation conventions

- `toKey(value)`: normalizes strings to uppercase trimmed keys (sorting, dedupe, case‑insensitive comparisons).
- `toInt(value, fallback)`: parses non‑negative integers; invalid/negative results become `fallback`.
- Item description is normalized with `String(...).replace(/[\r\n]+/g, ' ').trim()`.
- Phone numbers are auto‑formatted to `(XXX) XXX-XXXX` and strip a leading `1` if present.
- Email validation uses a simple regex (`looksLikeEmailAddress`).
- Dates in emails/reports are formatted in **America/New_York** via `Intl.DateTimeFormat` (`formatEasternDateTime`).

## UI layout

### Header

- Branding/logo (image): `.title-logo`
- **Profile menu** (right):
  - button: `#profileBtn`
  - status LED dot: `#profileStatus` with classes:
    - `.online` (green) when connected
    - `.offline` (red) when offline/not signed in
    - `.warning` (amber) when signed in but not authorized
  - dropdown: `#profileDropdown` (sign in/out + profile settings)
- **Hamburger menu**:
  - button: `#hamburgerBtn`
  - dropdown: `#menuDropdown`
  - backdrop: `#menuBackdrop`

### Main inventory card

- Filter input: `#filterBox` (+ clear button `#btnClearFilter`)
- Mobile sort select: `#mobileSort` (shown on smaller screens)
- Totals row (live metrics):
  - `#totalItems`, `#totalInStock`, `#totalLowStock`, `#totalQty`
- Inventory table: `#invTable`
  - columns: select checkbox, item name, description, qty (with stepper), actions
  - master checkbox: `#chkAll`
  - row checkboxes: `.rowChk` with `data-id`
  - action buttons:
    - per‑row low stock settings: `.row-stock-btn`
    - per‑row delete: `.row-delete-btn`

### Mobile “stacked card” table behavior

On small screens (`max-width: 768px`), rows render as stacked cards. The app highlights the row closest to the center of the scroll viewport using:

- `IntersectionObserver` rooted on `#tableWrap`
- a scroll listener (passive) on `#tableWrap`
- CSS class: `.scroll-focus` toggled on the “centered” row

### Mobile inventory gestures (Mobile UX v2)

When `isMobileUx()` is true (`max-width: 768px` OR `(pointer: coarse)`), the inventory list has additional mobile-only behaviors (specified in `CODEX_MOBILE_UX_V2.md`):

- **Tap card body**: toggles the item in the Order Engine (`state._order.lines`) (tap to add; tap again to remove).
- **Compact cards**: field labels like “Item” and “Description” are hidden to reduce vertical scrolling.
- **Swipe left/right**: slides the whole card (iMessage-style) to reveal a per-row utility tray with exactly two actions:
  - **Edit** → opens `#editItemModal`
  - **Low Stock** → opens `#lowStockModal`
- **Safety rule**: delete is only available inside `#editItemModal` (requires confirmation).
- **LED dots on each card**:
  - Order membership (on when the item is in the current order)
  - Low-stock override (on when `items.low_stock_qty` is non-null)

### Responsive sizing helpers

- `adjustTitleSize()`: dynamically adjusts the header title size to fit available width.
- `adjustDescColumnWidth()`: on desktop, measures description widths and clamps `#col-desc` for a readable single‑line layout; on mobile, allows wrapping.

## Inventory behaviors

### Sorting

- Desktop: clicking `#invTable thead th.sortable` toggles sort direction or sets a new sort column.
- Mobile: `#mobileSort` sets `{ col, dir }` directly.

### Filtering

- `#filterBox` updates `state._filter` on input and re-renders the table.
- Escape in `#filterBox` clears the filter.
- `#btnClearFilter` clears and re-focuses the filter input.

### Inline editing vs modal editing

Editing is driven by `startCellEdit(td, event)`:

- **Desktop/precise pointer**: turns the clicked cell into a temporary `<input>` editor.
  - `Enter`: commit
  - `Escape`: cancel
  - `blur`: commit
  - Clearing the filter: starting an edit clears `state._filter` so the row doesn’t disappear mid-edit.
- **Mobile/coarse pointer (or iOS)**: opens the modal editor (`#editItemModal`) via `openEditItemModal(id)`.

Validation rules during edits:

- Name: required and case‑insensitively unique.
- Qty: integer `≥ 0`.
- Description: line breaks collapsed to a single line.

### Qty stepper & debounced commits

The Qty column renders a `+/-` stepper. Clicking is handled by a delegated listener on `#invTable`:

- UI updates are immediate (optimistic).
- Totals are adjusted incrementally (without a full `renderTable()`).
- Server updates are **debounced** per item (`queueQtyCommit` → `flushQtyCommit`) to avoid sending a request for every tap.

### Per‑item Low Stock settings

Low stock thresholds are determined by:

1. Global low stock qty (`profiles.low_stock_qty_global` or local fallback `inv.pref.lowStockQtyGlobal`)
2. Optional per-item override (`items.low_stock_qty`)

There is also a per‑item toggle for reorder eligibility:

- `items.reorder_enabled` (defaults to `true` when missing)
- If `false`, the item is excluded from low‑stock counts and reorder suggestions.

#### Low Stock override indicator (LED dot)

If an item has a per-item low stock override (non‑null `low_stock_qty`), the row’s low‑stock icon button gets a small LED dot:

- CSS: `.row-stock-btn.has-override::after`
- Applied when rows render, and updated after saving the Low Stock modal (`syncLowStockOverrideIndicatorForRow`).

## Menus (header dropdowns)

### Hamburger menu actions

- **Import File** (`#menuImport`): opens file picker `#fileImport`.
- **Paste Data** (`#menuPaste`): opens `#pasteModal`.
- **Export File** (`#menuExport`): downloads current inventory as `inventory.csv`.
- **Create Inventory Report** (`#menuReport`): opens `#reportModal`.
- **Add Item** (`#menuAddOne`): opens `#addOneModal`.
- **Create Order** (`#menuOrder`): opens `#orderModal`.
- **Order History** (`#menuHistory`): opens `#orderHistoryModal`.

### Profile dropdown actions

- **Profile Settings** (`#openProfileSettings`): opens `#profileModal`.
- **Sign In / Sign Out** (`#profileSignIn`): opens `#authModal` or signs out via Supabase.

## Modals (by `id`)

All modals share:

- `.modal` backdrop container + `.box` content
- visibility toggled via `show(id, true/false)` which manages `aria-hidden` and auto-focus
- click on the backdrop closes most modals (except `#editItemModal`)

### `pasteModal` — Paste/Import data

Purpose: accept pasted table text or a dropped/chosen file.

Controls:

- drop zone: `#dropZone` (dragover/dragleave/drop)
- file input: `#fileImportModal`
- textarea: `#pasteArea`
- actions: `#btnPasteCancel`, `#btnPasteApply`

Flow:

1. Parse pasted text with `parseDelimitedSmart` + `rowsToItems`.
2. Parse files with `parseAnyFile(file)` (supports csv/tsv/txt/json/xlsx/xls/docx/doc/pdf).
3. Open `#previewModal` with the import diff.

### `previewModal` — Import preview

Purpose: show add/update/no-change counts before applying.

Controls:

- table body: `#previewBody`
- actions: `#btnPreviewCancel`, `#btnPreviewApply`

Apply behavior:

- Upserts into Supabase via `sbUpsertMany(importRows)` and then refreshes via `sbLoadSnapshot()`.

### `addOneModal` — Add a single item

Controls:

- `#addName`, `#addDesc`, `#addQty`
- actions: `#btnAddCancel`, `#btnAddSave`

Rules:

- Name required, unique (case‑insensitive)
- Qty must be integer `> 0`

### `editItemModal` — Mobile-friendly editor

Purpose: larger touch targets + reliable cursor behavior on mobile.

Controls:

- `#editItemName`, `#editItemDesc`, `#editItemQty`
- qty stepper: `#editItemQtyMinus`, `#editItemQtyPlus`
- actions: `#btnEditItemCancel`, `#btnEditItemSave`

Keyboard:

- `Escape`: cancel/close
- `Enter` behavior:
  - name input: moves to description (mobile “Done” UX)
  - qty input: saves
  - description: `Cmd/Ctrl+Enter` saves

### `lowStockModal` — Per-item low stock threshold

Controls:

- labels: `#lowStockItemLabel`, `#lowStockCurrentLabel`, `#lowStockGlobalLabel`
- qty: `#lowStockValue` + steppers `#lowStockMinus`, `#lowStockPlus`
- toggle: `#lowStockReorderEnabled`
- actions: `#btnLowStockUseGlobal`, `#btnLowStockCancel`, `#btnLowStockSave`

Behavior:

- Blank input means “use global”.
- `Use Global` sets the modal to “global mode” and stores `low_stock_qty = null` when saved.
- `Enter` saves, `Escape` cancels.
- After save, the table’s low-stock totals and the override LED indicator update without requiring a full re-render (when possible).

### `reportModal` — Inventory report

Shows:

- summary metrics: total items, in stock, low stock, total qty
- Low Stock Items section (if any) with “Re-order Low Stock Items”
- Current Inventory section (collapsible; defaults collapsed on mobile)

Actions:

- `#btnReportDownload`: download report CSV
- `#btnReportShare`: opens `#reportEmailModal`
- `#btnReportBuildReorder`: builds an order from low-stock items
- `#btnReportClose`: close

Low stock calculation uses:

- `effectiveLowStockQty(item)` and `isLowStockItem(item)`
- `reorder_enabled` is respected (disabled items do not count as low stock)

### `reportEmailModal` — Email inventory report

Controls:

- `#reportEmailTo`, `#reportEmailSubject`
- preview container: `#reportEmailPreview`
- actions: `#btnReportEmailCopy`, `#btnReportEmailSend`, `#btnReportEmailClose`

Send behavior:

- Sends HTML via the same API path used by the Order Engine (`getOrderApiUrl()`), with optional Supabase auth headers when targeting an Edge Function.

### `orderModal` — Create/send a material order

Sections:

- inventory search: `#orderSearch` + `#btnClearOrderSearch`
- search results container: `#orderResultsBody`
- order lines container: `#orderLinesBody`
- recipient email: `#orderEmail` + suggestions `#orderEmailSuggest`
- message fields: `#orderSubject`, `#orderNotes`
- HTML preview: `#orderPreviewHtml`

Actions:

- `#btnOrderCancel`: close
- `#btnOrderCopy`: copy plain‑text order body
- `#btnOrderSubmit`: send order

Key behaviors:

- Selected inventory rows (`.rowChk:checked`) are added to the order when opening the modal (unless `openOrderModal({ addSelected:false })` is used).
- The “Send” button is disabled unless:
  - recipient email is present
  - at least one order line has qty > 0

Sending:

- Primary path: `sendOrderPayloadViaApi` (Edge Function or `/api/send-order`).
- Fallback: on failure, prompts to open the mail client via a generated `mailto:` URL.
- After sending, it attempts to:
  - record the recipient in `order_recipients` (autocomplete)
  - store the order in `orders` (history)

### `orderHistoryModal` — Order history

Controls:

- list: `#orderHistoryList` (renders `<details>` items)
- filter: `#orderHistoryFilter` + `#btnClearOrderHistoryFilter`
- actions: `#btnOrderHistoryDownload`, `#btnOrderHistoryRefresh`, `#btnOrderHistoryClose`

Features:

- CSV download of all orders (paginated fetch behind the scenes)
- Per-order “Forward” UI to re-send an order to another recipient (uses the same send API + recipients suggestions)
- Per-order delete (with confirmation) when enabled in the UI

### `authModal` — Sign in / sign up / magic link

Controls:

- `#authEmail`, `#authPassword`
- actions:
  - `#btnAuthMagic`: send magic link
  - `#btnAuthToggleMode`: toggle sign-in vs sign-up
  - `#btnAuthSubmit`: submit current mode

Notes:

- Sign-up enforces a minimum password length (6).
- Magic link uses `signInWithOtp` with `emailRedirectTo: location.href`.

### `profileModal` — Account/profile settings

Controls:

- `#profileFirstName`, `#profileLastName`
- `#profilePhone` (auto-formatted)
- `#profileDeliveryAddress`
- `#profileLowStockQtyGlobal` (integer ≥ 0)
- `#profileSilenceLowStockAlerts` (persisted; currently used as a stored preference)
- actions: `#btnProfileClose`, `#btnSignOut`, `#btnProfileSave`

### `msgModal` — App message/alert replacement

Controls:

- title/body: `#msgTitle`, `#msgBody`
- actions: `#btnMsgOk`, `#btnMsgCopy` (only visible when copy text is provided)

Used for:

- Supabase schema cache help prompts (copies `NOTIFY pgrst, 'reload schema';` when possible)

### `confirmModal` — App confirm replacement

Controls:

- title/body: `#confirmTitle`, `#confirmBody`
- actions: `#btnConfirmCancel`, `#btnConfirmOk`

Keyboard:

- `Escape` cancels (only when confirm modal is open)

## Import parsing (details)

### Delimited text (`parseDelimitedSmart`)

- Detects delimiter based on the first line: tab vs comma vs multi‑space.
- Supports quoted fields with `""` escapes.
- Returns a 2D array of rows/columns (empty rows removed).

### Table-to-items mapping (`rowsToItems`)

- Attempts to detect headers using canonicalized names:
  - Item: `Item` / `Name`
  - Description: `Description` / `Desc`
  - Qty: `Qty` / `Quantity` / `Count` / `QuantityOnHand`
- If no header is detected, defaults to columns `[0]=Item, [1]=Description, [2]=Qty`.

### File formats (`parseAnyFile`)

- `csv/tsv/txt`: uses `parseDelimitedSmart` + `rowsToItems`
- `json`: supports either:
  - `{ items: [...] }`, or
  - `[...]` with flexible key names
- `xlsx/xls`: lazily loads SheetJS (`xlsx`) from jsDelivr, reads first sheet
- `docx/doc`: lazily loads `mammoth`, extracts tables first, then falls back to paragraph heuristics
- `pdf`: lazily loads `pdf.js`, reconstructs lines by Y/X positions and tries delimiter parsing

## Connectivity & gating

All “write” actions use `requireOnline()` to enforce:

1. Supabase configured
2. user signed in
3. user authorized (`authorized_users` contains the user_id)
4. server reachable (health check)

If the gate fails, a toast explains why, and sign-in prompts open as needed.

The app keeps connectivity status fresh via:

- `window` `online`/`offline` events
- a periodic `checkServerHealth()` interval (15s)

## Service worker update flow

- Registers: `navigator.serviceWorker.register('./sw.js?v=14', { scope: './' })`
- When the controlling SW changes, the app shows a toast and reloads after a short delay.
- `sw.js` uses:
  - network‑first caching for HTML navigations
  - cache‑first for other same‑origin assets

## Event listener index (high level)

This is a categorized map of the important listeners and where they attach:

- **Global**
  - `document.click`: modal backdrop close; row action delegation; order history actions (forward, delete, etc.); profile dropdown close
  - `document.change`: master checkbox and row checkbox indeterminate state
  - `document.keydown`: escape to close hamburger menu; escape to cancel confirm modal
  - `document.focusin/focusout`: iOS keyboard-safe `.scroll` height adjustment
- **Inventory**
  - `#filterBox`: `input` (filter), `keydown` Escape (clear)
  - `#btnClearFilter`: `click` (clear filter)
  - `#invTable thead th.sortable`: `click` (sort)
  - `#mobileSort`: `change` (sort)
  - `#invTable`: delegated `click` on `.qty-step-btn` (qty +/-)
  - `#invTable`: delegated `click` on `.card-tray-btn` (mobile tray actions)
  - `#invTable`: `pointerdown/move/up/cancel` (mobile swipe/tap gestures for non-touch pointers)
  - `#invTable`: `touchstart/move/end/cancel` (mobile swipe/tap gestures for touch)
- **Hamburger menu**
  - `#hamburgerBtn`: `click` (toggle)
  - `#menuBackdrop`: `click` (close)
- **Import**
  - `#fileImport`, `#fileImportModal`: `change` (file import)
  - `#dropZone`: drag/drop events
  - `#btnPasteApply`, `#btnPasteCancel`: import actions
  - `#btnPreviewApply`, `#btnPreviewCancel`: preview actions
- **Low stock**
  - `.row-stock-btn`: delegated `click` (open modal)
  - modal buttons/inputs: `click`, `keydown`, `input` to edit/save/cancel
- **Orders**
  - `#orderSearch`: `input` + Escape to clear; `#btnClearOrderSearch` click
  - `#orderResultsBody`: delegated `click` on stepper buttons (add/remove)
  - `#orderLinesBody`: delegated `click` (remove / inc / dec)
  - `#orderEmail`: `input`/`focus`/`blur` (suggestions)
  - `#orderEmailSuggest`: delegated `click` (apply suggestion)
  - `#btnOrderCopy`, `#btnOrderSubmit`, `#btnOrderCancel`: primary actions
- **Reports**
  - report modal buttons: close/download/share/reorder build
  - report email modal: copy/send/close
- **Auth/profile**
  - auth modal buttons + password Enter
  - profile modal save/sign out/close + phone input formatting
