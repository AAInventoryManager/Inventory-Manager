import { describe, it, expect } from 'vitest';
import {
  toInt,
  toKey,
  parseDelimitedSmart,
  rowsToItems,
  normalizeImpersonationRole,
  ensureImpersonationRole,
  buildImpersonationRoleOptions
} from '../../src/utils.js';

describe('utils', () => {
  it('toKey normalizes text', () => {
    expect(toKey('  hello ')).toBe('HELLO');
    expect(toKey('Ab c')).toBe('AB C');
    expect(toKey('')).toBe('');
  });

  it('toInt floors and guards negatives', () => {
    expect(toInt('10', 0)).toBe(10);
    expect(toInt('10.9', 0)).toBe(10);
    expect(toInt('-3', 0)).toBe(0);
    expect(toInt('nope', 5)).toBe(5);
  });

  it('parseDelimitedSmart detects tabs and commas', () => {
    const tabText = 'Item\tDescription\tQty\nWidget\tTest\t5';
    const commaText = 'Item,Description,Qty\nWidget,Test,5';
    expect(parseDelimitedSmart(tabText)).toHaveLength(2);
    expect(parseDelimitedSmart(commaText)).toHaveLength(2);
  });

  it('rowsToItems maps rows into inventory items', () => {
    const rows = [
      ['Item', 'Description', 'Qty'],
      ['Widget', 'Example', '7']
    ];
    const items = rowsToItems(rows);
    expect(items).toHaveLength(1);
    expect(items[0]).toEqual({ name: 'Widget', desc: 'Example', qty: 7 });
  });
});

describe('impersonation helpers', () => {
  it('normalizes roles and rejects unknown values', () => {
    expect(normalizeImpersonationRole(' Admin ')).toBe('admin');
    expect(normalizeImpersonationRole('owner')).toBe('');
  });

  it('ensures a safe fallback role', () => {
    expect(ensureImpersonationRole('')).toBe('super_user');
    expect(ensureImpersonationRole('viewer')).toBe('viewer');
  });

  it('always includes super_user in role options', () => {
    expect(buildImpersonationRoleOptions(['admin', 'member'])).toEqual(['super_user', 'admin', 'member']);
  });
});
