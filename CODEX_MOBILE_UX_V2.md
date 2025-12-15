# CODEX_MOBILE_UX_V2.md

## Inventory Manager — Mobile UX Update Codex

This document defines **mobile-only UX updates** to the Inventory list experience.
It is the authoritative specification for these changes.

Desktop behavior is explicitly out of scope.

---

## 1. Scope

### In Scope

- Mobile inventory card interactions
- Card tap behavior
- Swipe gesture behavior
- Status indicators (LED dots)
- Removal of checkbox-based selection on mobile

### Out of Scope (Must Not Change)

- Desktop inventory table behavior
- Supabase schema or API calls
- Order Engine data model
- Quantity debouncing / commit logic
- Filtering and sorting logic
- Desktop inline editing behavior

---

## 2. Mobile Definition

The rules in this codex apply when **any** of the following are true:

- Viewport width ≤ `768px`
- Pointer is coarse (`(pointer: coarse)`)

Outside these conditions, the app behaves exactly as defined in `APP_REFERENCE.md`.

---

## 3. UX Summary (Mobile Only)

- Inventory rows render as tappable cards
- Cards are compact: field labels like “Item” and “Description” are not shown
- Tapping a card toggles the item in the Create Order engine (add/remove)
- Quantity steppers remain the primary interaction
- Swipe gestures slide the whole card (iMessage-style) to reveal utility actions (Edit, Low Stock)
- No destructive actions exist on the card
- Delete is only available inside the Edit Item modal
- Two LED dots communicate item state

---

## 4. Inventory Card — Mobile Behavior

### 4.1 Card Tap → Toggle Order (Add/Remove)

On mobile, tapping the **card body** performs the following:

- If the item is **not** in the order: add it to the Create Order engine
- If the item **is** already in the order: remove it from the Create Order engine
- Inventory quantity is **not modified**

### Guard Conditions

Card tap **must be ignored** when:

- Tap originates from quantity stepper buttons
- Swipe tray is open
- Pointer movement exceeds swipe threshold

---

## 5. Quantity Steppers (Priority Interaction)

- Quantity `+ / −` steppers remain visually dominant
- Minimum tap target size: **48×48 px**
- Quantity updates remain optimistic and debounced
- Swipe gestures must be disabled while interacting with steppers

Quantity entry is the highest-priority interaction on mobile.

---

## 6. Swipe Interaction Specification

### 6.1 Swipe Availability

- Swipe gestures are enabled on inventory cards (mobile only)
- Vertical scrolling always takes priority over horizontal swipe
- Only one swipe tray may be open at a time

### 6.2 Swipe Tray Contents

Swiping **either direction** reveals a utility tray containing **exactly two actions**:

1. **Edit Item (✏️)**

   - Opens the Edit Item modal

2. **Low Stock Override (⚠️)**
   - Opens the Low Stock modal

### Explicitly Excluded

- No swipe-to-delete
- No swipe-to-add
- No auto-executing swipe actions

All swipe actions require an explicit tap.

---

## 7. Delete Behavior (Safety Rule)

- Delete is ONLY available inside the Edit Item modal
- No delete controls exist on inventory cards
- Delete always requires confirmation

There are **no destructive gestures** in the inventory list.

---

## 8. LED Status Indicators (Mobile Cards)

Each mobile inventory card displays **two small, non-interactive LED dots**.

### 8.1 LED #1 — Order State

Indicates whether the item is part of the current order.

- **ON** when:
  - Item exists in `state._order.lines`
- **OFF** when:
  - Item is not part of the order

### 8.2 LED #2 — Low Stock Override

Indicates whether the item overrides the global low-stock value.

- **ON** when:
  - `items.low_stock_qty` is non-null
- **OFF** when:
  - Global low-stock value is used

### Visual Rules

- LEDs are informational only
- LEDs are not clickable
- LEDs must not compete visually with qty controls
- Recommended size: 6–8 px

---

## 9. Interaction Priority Order (Mobile)

The following priority must be preserved:

1. Quantity steppers
2. Card tap (Add to Order)
3. Swipe tray actions
4. LED indicators (read-only)
5. Delete (Edit modal only)

No interaction may interfere with a higher-priority interaction.

---

## 10. Technical Integration Notes

- Card tap handling should be implemented via delegated listeners on `#invTable`
- Swipe gestures should use pointer events (`pointerdown / pointermove / pointerup`) with a touch fallback when needed
- Apply `touch-action: pan-y` to swipe containers
- Swipe must be disabled while:
  - Qty steppers are active
  - A modal is open
- Reduced-motion preferences must be respected

---

## 11. Non-Regression Checklist

The following must remain unchanged:

- Desktop inventory table layout
- Desktop checkbox behavior (if retained)
- Qty commit debouncing
- Filter input behavior
- Mobile sort behavior
- Order Engine send logic
- Supabase realtime sync

---

## 12. Canonical Intent

This mobile UX is designed for **fast, safe, field use**:

- State is communicated visually, not via controls
- Destructive actions are intentional and guarded
- Frequent actions are optimized
- Rare actions are discoverable but hidden

This codex is the source of truth for mobile inventory UX.
