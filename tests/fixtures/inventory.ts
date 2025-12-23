export const TEST_INVENTORY_ITEMS = [
  { company: 'MAIN', name: 'Test Item 1', quantity: 100, sku: 'TEST-001' },
  { company: 'MAIN', name: 'Test Item 2', quantity: 50, sku: 'TEST-002' },
  { company: 'MAIN', name: 'Low Stock Item', quantity: 5, low_stock_qty: 10, sku: 'TEST-003' },
  { company: 'MAIN', name: 'Out of Stock', quantity: 0, low_stock_qty: 10, sku: 'TEST-004' },
  { company: 'OTHER', name: 'Other Company Item', quantity: 200, sku: 'OTHER-001' }
] as const;
