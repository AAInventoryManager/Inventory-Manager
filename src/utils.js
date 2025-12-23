export function toKey(value) {
  return String(value || '').trim().toUpperCase();
}

export function toInt(value, fallback = 0) {
  const num = Number(value);
  if (!Number.isFinite(num)) return fallback;
  const floored = Math.floor(num);
  return floored < 0 ? fallback : floored;
}

export function parseDelimitedSmart(text) {
  const firstLine = (String(text || '').split(/\r?\n/)[0] || '');
  let delim = '\t';
  const tabScore = (firstLine.split('\t').length - 1);
  const commaScore = (firstLine.split(',').length - 1);
  const spaceScore = ((firstLine.match(/\s{2,}/g) || []).length);
  if (commaScore > tabScore && commaScore >= spaceScore) {
    delim = ',';
  } else if (spaceScore > tabScore && spaceScore > commaScore) {
    delim = '  ';
  }

  const rows = [];
  let row = [];
  let field = '';
  let inQ = false;
  let i = 0;
  const input = String(text || '');
  const total = input.length;
  const isDelim = (ch, pk) => (
    delim === '\t' ? ch === '\t' : (delim === ',' ? ch === ',' : (ch === ' ' && pk === ' '))
  );

  while (i < total) {
    const ch = input[i];
    const pk = input[i + 1];
    if (ch === '"') {
      if (inQ && pk === '"') {
        field += '"';
        i += 2;
        continue;
      }
      inQ = !inQ;
      i += 1;
      continue;
    }
    if (!inQ && (isDelim(ch, pk) || ch === '\n')) {
      row.push(field);
      field = '';
      if (delim === '  ' && ch === ' ' && pk === ' ') {
        while (input[i] === ' ') i += 1;
        continue;
      }
      if (ch === '\n') {
        rows.push(row);
        row = [];
      }
      i += 1;
      continue;
    }
    if (ch === '\r') {
      i += 1;
      continue;
    }
    field += ch;
    i += 1;
  }

  if (field.length || row.length) {
    row.push(field);
    rows.push(row);
  }

  return rows.filter(r => r.some(c => String(c).trim().length));
}

export function rowsToItems(rows) {
  if (!rows || !rows.length) return [];
  const canon = (value) => toKey(String(value).replace(/[^A-Za-z0-9]+/g, '').trim());
  const hdrsRaw = rows[0] || [];
  const hdrs = hdrsRaw.map(canon);
  const idxFromHdr = (names) => {
    for (const name of names) {
      const idx = hdrs.indexOf(name);
      if (idx >= 0) return idx;
    }
    return -1;
  };
  let iItem = idxFromHdr(['ITEM', 'NAME']);
  let iDesc = idxFromHdr(['DESCRIPTION', 'DESC']);
  let iQty = idxFromHdr(['QTY', 'QUANTITY', 'COUNT', 'QUANTITYONHAND']);
  const hasHeader = iItem >= 0;
  if (!hasHeader) {
    iItem = 0;
    iDesc = 1;
    iQty = 2;
  }

  const start = hasHeader ? 1 : 0;
  const out = [];
  for (let r = start; r < rows.length; r += 1) {
    const row = rows[r] || [];
    const name = String(row[iItem] !== undefined ? row[iItem] : '').trim();
    if (!name) continue;
    const desc = String((iDesc >= 0 && row[iDesc] !== undefined ? row[iDesc] : '')).trim();
    const qtyV = (iQty >= 0 && row[iQty] !== undefined) ? row[iQty] : 0;
    const qty = toInt(qtyV, 0);
    out.push({ name, desc, qty });
  }
  return out;
}

if (typeof window !== 'undefined') {
  const existing = window.IMUtils || {};
  window.IMUtils = {
    ...existing,
    toKey: existing.toKey || toKey,
    toInt: existing.toInt || toInt,
    parseDelimitedSmart: existing.parseDelimitedSmart || parseDelimitedSmart,
    rowsToItems: existing.rowsToItems || rowsToItems
  };
}
