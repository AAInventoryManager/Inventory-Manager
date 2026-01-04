# Table Column Defaults

## INVENTORY_LIST

Default columns:
- key: item
  label: Item
  visibility: on
  lock: true
- key: sku
  label: SKU
  visibility: on
  lock: false
- key: on_hand
  label: On Hand
  visibility: on
  lock: false
- key: available
  label: Available
  visibility: on
  lock: false
- key: reorder_point
  label: Reorder Point
  visibility: on
  lock: false
- key: actions
  label: Actions
  visibility: on
  lock: false

Optional columns:
- key: description
  label: Description
  visibility: off
  lock: false
- key: reserved
  label: Reserved
  visibility: off
  lock: false
- key: reorder_qty
  label: Reorder Qty
  visibility: off
  lock: false
- key: location
  label: Location
  visibility: off
  lock: false
- key: category
  label: Category
  visibility: off
  lock: false
- key: last_updated
  label: Last Updated
  visibility: off
  lock: false
