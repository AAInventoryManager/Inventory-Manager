// ============================================================================
// INBOUND RECEIPT EMAIL HANDLER (SendGrid Inbound Parse)
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { jsonResponse } from '../utils/responses.ts';
import { logger } from '../utils/logger.ts';
import type { AuthContext } from '../middleware/auth.ts';

const MAX_BODY_BYTES = 15 * 1024 * 1024; // 15MB
const DEFAULT_DOMAIN = 'inbound.inventorymanager.app';
const LEGACY_DOMAIN = 'inventorymanager.app';
const DEFAULT_DEDUPE_WINDOW_DAYS = 14;
const DEFAULT_ATTACHMENT_BUCKET = 'receipt-attachments';

interface ParsedLineItem {
  description: string;
  sku: string | null;
  qty: number | null;
  unit_price: number | null;
  line_total: number | null;
}

interface ParsedReceipt {
  vendor_name: string | null;
  receipt_date: string | null;
  subtotal: number | null;
  tax: number | null;
  total: number | null;
  line_items: ParsedLineItem[];
}

type AttachmentStorageProvider = 'supabase' | 'external';

function getServiceClient() {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') || '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!supabaseUrl || !serviceKey) {
    throw new Error('Missing Supabase service configuration');
  }
  return createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function base64ToBytes(raw: string): Uint8Array {
  const normalized = raw.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function verifySendgridSignature(request: Request, rawBody: Uint8Array): Promise<boolean> {
  const signature = request.headers.get('x-twilio-email-event-webhook-signature')
    || request.headers.get('x-sendgrid-signature')
    || '';
  const timestamp = request.headers.get('x-twilio-email-event-webhook-timestamp')
    || request.headers.get('x-sendgrid-timestamp')
    || '';
  const publicKey = Deno.env.get('SENDGRID_INBOUND_PUBLIC_KEY')
    || Deno.env.get('SENDGRID_WEBHOOK_PUBLIC_KEY')
    || '';

  if (!signature || !timestamp || !publicKey) return false;

  try {
    const keyBytes = base64ToBytes(publicKey);
    const sigBytes = base64ToBytes(signature);
    const prefix = new TextEncoder().encode(timestamp);
    const message = new Uint8Array(prefix.length + rawBody.length);
    message.set(prefix, 0);
    message.set(rawBody, prefix.length);
    const key = await crypto.subtle.importKey(
      'raw',
      keyBytes,
      { name: 'Ed25519' },
      false,
      ['verify']
    );
    return await crypto.subtle.verify('Ed25519', key, sigBytes, message);
  } catch (err) {
    logger.warn('SendGrid signature verification failed', { error: err instanceof Error ? err.message : String(err) });
    return false;
  }
}

function extractEmails(text: string): string[] {
  const matches = String(text || '').match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi);
  if (!matches) return [];
  return matches.map(m => m.trim()).filter(Boolean);
}

function extractSlugFromRecipients(recipients: string[], domain: string): string | null {
  const targetDomain = String(domain || '').toLowerCase();
  for (const raw of recipients) {
    const addr = String(raw || '').trim().toLowerCase();
    const match = addr.match(/^receipts\+([a-z0-9-]+)@([a-z0-9.-]+)$/);
    if (!match) continue;
    if (match[2] !== targetDomain) continue;
    return match[1];
  }
  return null;
}

function decodeHtmlEntities(text: string): string {
  return String(text || '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&apos;/gi, "'")
    .replace(/&#(\d+);/g, (_, num) => String.fromCharCode(parseInt(num, 10)))
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function stripHtmlToText(html: string): string {
  const raw = String(html || '').trim();
  if (!raw) return '';
  try {
    const parser = new DOMParser();
    const doc = parser.parseFromString(raw, 'text/html');
    const text = doc?.body?.innerText || doc?.body?.textContent || '';
    return decodeHtmlEntities(String(text || '').replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim());
  } catch {
    return decodeHtmlEntities(raw
      .replace(/<style[\s\S]*?<\/style>/gi, '\n')
      .replace(/<script[\s\S]*?<\/script>/gi, '\n')
      .replace(/<br\s*\/?\s*>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim());
  }
}

function parseMoney(value: string): number | null {
  const cleaned = String(value || '').replace(/[^0-9.\-]/g, '');
  if (!cleaned) return null;
  const num = Number.parseFloat(cleaned);
  return Number.isFinite(num) ? num : null;
}

function parseDate(value: string): string | null {
  const raw = String(value || '').trim();
  if (!raw) return null;
  const normalized = raw.replace(/[\u2013\u2014]/g, '-').replace(/(\d)(st|nd|rd|th)\b/gi, '$1');
  const monthIndex = (name: string): number => {
    const key = name.trim().toLowerCase().slice(0, 3);
    const map: Record<string, number> = {
      jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
      jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
    };
    return map[key] || 0;
  };
  const normalizeYear = (yearRaw: string): number => {
    const num = Number.parseInt(yearRaw, 10);
    if (!Number.isFinite(num)) return 0;
    if (yearRaw.length === 2) return num >= 70 ? 1900 + num : 2000 + num;
    return num;
  };
  const buildDate = (year: number, month: number, day: number): string | null => {
    if (!year || month < 1 || month > 12 || day < 1 || day > 31) return null;
    const probe = new Date(Date.UTC(year, month - 1, day));
    if (probe.getUTCFullYear() !== year || probe.getUTCMonth() !== month - 1 || probe.getUTCDate() !== day) {
      return null;
    }
    const mm = String(month).padStart(2, '0');
    const dd = String(day).padStart(2, '0');
    return `${year}-${mm}-${dd}`;
  };
  let match = normalized.match(/\b(\d{4})[\/\-\.](\d{1,2})[\/\-\.](\d{1,2})\b/);
  if (match) {
    return buildDate(Number(match[1]), Number(match[2]), Number(match[3]));
  }
  match = normalized.match(/\b([A-Za-z]{3,9})\.?\s+(\d{1,2})\s*,?\s*(\d{2,4})\b/);
  if (match) {
    const month = monthIndex(match[1]);
    const year = normalizeYear(match[3]);
    return buildDate(year, month, Number(match[2]));
  }
  match = normalized.match(/\b(\d{1,2})\s+([A-Za-z]{3,9})\.?\s+(\d{2,4})\b/);
  if (match) {
    const month = monthIndex(match[2]);
    const year = normalizeYear(match[3]);
    return buildDate(year, month, Number(match[1]));
  }
  match = normalized.match(/\b(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})\b/);
  if (match) {
    const a = Number(match[1]);
    const b = Number(match[2]);
    const year = normalizeYear(match[3]);
    if (a > 12 && b <= 12) return buildDate(year, b, a);
    if (b > 12 && a <= 12) return buildDate(year, a, b);
    return null;
  }
  return null;
}

function parseQuantity(value: string): number | null {
  const cleaned = String(value || '').replace(/[^0-9.\-]/g, '');
  if (!cleaned) return null;
  const num = Number.parseFloat(cleaned);
  return Number.isFinite(num) ? num : null;
}

function normalizeReceiptLines(text: string): string[] {
  const raw = String(text || '')
    .replace(/\r\n/g, '\n')
    .replace(/\u00a0/g, ' ');
  return raw
    .split('\n')
    .map(line => line.replace(/\s+/g, ' ').trim())
    .filter(Boolean);
}

function isLikelyVendorLine(line: string): boolean {
  const trimmed = String(line || '').trim();
  if (!trimmed || trimmed.length > 80 || trimmed.length < 2) return false;
  const lower = trimmed.toLowerCase();
  if (/@/.test(trimmed) || /https?:\/\//i.test(trimmed) || /www\./i.test(trimmed)) return false;
  if (/\b(receipt|invoice|statement|order|purchase|subtotal|total|tax)\b/i.test(lower)) return false;
  if (/\b(thank you|thanks|welcome|customer|member)\b/i.test(lower)) return false;
  if (/\b(street|st\.|road|rd\.|avenue|ave\.|blvd|drive|dr\.|lane|ln\.|way|suite|ste\.|unit|apt|po box|box|zip)\b/i.test(lower)) return false;
  if (/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/.test(lower)) return false;
  if (/^\d+$/.test(trimmed)) return false;
  const digitCount = (trimmed.match(/\d/g) || []).length;
  const letterCount = (trimmed.match(/[A-Za-z]/g) || []).length;
  if (letterCount < 2 || digitCount > letterCount) return false;
  return true;
}

function extractVendorFromLabels(lines: string[]): string | null {
  const labelRegex = /^\s*(vendor|from|sold by|seller|merchant|store)\s*[:\-]\s*(.+)$/i;
  for (const line of lines) {
    const match = line.match(labelRegex);
    if (!match) continue;
    const candidate = String(match[2] || '').trim()
      .replace(/<[^>]*>/g, '')  // Remove <email> or other angle-bracketed content
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '')
      .replace(/https?:\/\/\S+/gi, '')
      .replace(/www\.\S+/gi, '')
      .replace(/\s+/g, ' ')  // Normalize whitespace
      .trim();
    if (isLikelyVendorLine(candidate)) return candidate;
  }
  return null;
}

function extractDateFromLine(line: string): string | null {
  const patterns = [
    /\b(\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2})\b/,
    /\b(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})\b/,
    /\b([A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4})\b/,
    /\b(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{2,4})\b/,
  ];
  for (const pattern of patterns) {
    const match = line.match(pattern);
    if (!match) continue;
    const parsed = parseDate(match[1]);
    if (parsed) return parsed;
  }
  return null;
}

function isTotalsIndicator(line: string): boolean {
  const lower = line.toLowerCase();
  if (/\b(total savings|savings total)\b/.test(lower)) return true;
  return /\b(subtotal|sub total|tax|sales tax|vat|gst|hst|pst|total|amount due|balance due|total due|order total|grand total|payment|paid|change|tip|discount|shipping|delivery)\b/.test(lower);
}

function extractLabeledAmount(lines: string[], labels: string[], exclude: RegExp[] = []): number | null {
  for (const label of labels) {
    const labelPattern = label
      .split(/\s+/)
      .map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
      .join('\\s+');
    // Look for $ followed by amount (handles "Subtotal $ 51.84" format)
    const dollarRegex = new RegExp(`\\b${labelPattern}\\b[^\\$]*\\$\\s*([0-9][0-9,]*\\.?[0-9]{0,2})`, 'i');
    // Fallback: number after label
    const fallbackRegex = new RegExp(`\\b${labelPattern}\\b[^0-9\\-]{0,20}(-?\\$?\\s*[0-9][0-9,]*\\.?[0-9]{0,2})`, 'i');
    // Label-only pattern (for multi-line format)
    const labelOnlyRegex = new RegExp(`^\\s*${labelPattern}\\s*$`, 'i');

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const lower = line.toLowerCase();
      if (exclude.some(re => re.test(lower))) continue;
      if (!new RegExp(`\\b${labelPattern}\\b`, 'i').test(line)) continue;

      // Try dollar sign pattern first (same line)
      const dollarMatch = line.match(dollarRegex);
      if (dollarMatch) {
        const val = parseMoney(dollarMatch[1]);
        if (val !== null) return val;
      }

      // Check if label is on its own line, value on next line (e.g., "Total Tax\n$ 3.63")
      if (labelOnlyRegex.test(line) && i + 1 < lines.length) {
        const nextLine = lines[i + 1];
        const nextMatch = nextLine.match(/^\s*\$?\s*([0-9][0-9,]*\.?\d{0,2})\s*$/);
        if (nextMatch) {
          const val = parseMoney(nextMatch[1]);
          if (val !== null) return val;
        }
      }

      // Fallback to original pattern, but skip if line has "invoice/order + number" before label
      if (/\b(invoice|order)\s+\d+\s+/i.test(line)) continue;
      const match = line.match(fallbackRegex);
      if (match) {
        const val = parseMoney(match[1]);
        if (val !== null) return val;
      }
    }
  }
  return null;
}

function isLineItemExcluded(line: string): boolean {
  const lower = line.toLowerCase();
  const trimmed = line.trim();

  // Exclude table headers (single words like "Item", "Price", "Qty", "Description")
  if (/^\s*(item|price|qty|quantity|description|amount|unit|total|sku)\s*$/i.test(trimmed)) return true;

  // Exclude summary/payment lines
  if (/\b(subtotal|sub total|tax|total|amount due|balance due|payment|paid|change|tip|shipping|delivery|order|invoice|receipt|cash|card|visa|mastercard|amex|debit|credit|auth|approval|customer|account|tracking|ship to|bill to|refid|terminal|mylowe|rewards|points|survey|feedback)\b/.test(lower)) {
    return true;
  }
  if (/\b(total savings|savings total)\b/.test(lower)) return true;

  // Exclude discount lines (e.g., "3.88 Discount Ea -0.39")
  if (/\bdiscount\b/i.test(lower)) return true;

  // Exclude item number/SKU lines (e.g., "Item #: 7384") - these are extracted separately
  if (/^\s*item\s*#?\s*:?\s*\d+\s*$/i.test(line)) return true;
  if (/^\s*sku\s*:?\s*\d+\s*$/i.test(line)) return true;

  // Exclude quantity-only lines (e.g., "2 @ 21.98")
  if (/^\s*\d+\s*@\s*[\d.,]+\s*$/i.test(line)) return true;

  // Exclude store location/address lines
  if (/\b(store\s*#?\s*:?\s*\d+|store number)\b/i.test(line)) return true;
  if (/\b[A-Za-z]+\s*,\s*[A-Z]{2}\s*\d{5}(-\d{4})?\b/.test(line)) return true; // City, ST 12345
  if (/\b[A-Za-z]+\s*,\s*[A-Z]{2}\s*$/i.test(line)) return true; // "Melbourne, FL" format

  // Exclude date-only lines (e.g., "December 31 2025", "01/15/2024")
  if (/^\s*[A-Za-z]+\s+\d{1,2}\s+\d{2,4}\s*$/i.test(line)) return true; // Month Day Year
  if (/^\s*\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}\s*$/i.test(line)) return true; // MM/DD/YYYY
  if (/^\s*\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2}\s*$/i.test(line)) return true; // YYYY-MM-DD

  // Exclude auth/time lines (e.g., "AuthTime", "AuthCD", "000000")
  if (/^\s*(authtime|authcd|refid)\s*$/i.test(trimmed)) return true;
  if (/^\s*\d{6}\s*$/i.test(trimmed)) return true; // 6-digit auth codes

  // Exclude balance/card lines
  if (/\b(balance|card transaction|remaining|beginning)\b/i.test(lower)) return true;

  return false;
}

function isLikelyItemDescription(desc: string): boolean {
  const trimmed = String(desc || '').trim();
  if (!trimmed || trimmed.length < 2 || trimmed.length > 160) return false;
  const lower = trimmed.toLowerCase();
  if (isLineItemExcluded(lower)) return false;
  if (/@/.test(trimmed) || /https?:\/\//i.test(trimmed) || /www\./i.test(trimmed)) return false;
  const digits = (trimmed.match(/\d/g) || []).length;
  const letters = (trimmed.match(/[A-Za-z]/g) || []).length;
  if (letters < 2) return false;
  if (digits > letters * 1.2) return false;
  return true;
}

function parseLineItem(line: string): ParsedLineItem | null {
  const cleaned = String(line || '').replace(/^[\u2022\-\*\•]+/, '').replace(/\s+/g, ' ').trim();
  if (!cleaned || cleaned.length < 3) return null;
  if (isLineItemExcluded(cleaned)) return null;
  const patterns: Array<RegExp> = [
    /^(?<desc>.+?)\s+(?<qty>\d+(?:\.\d+)?)\s*(?:x|@)\s*\$?(?<unit>\d[\d,]*\.?\d{0,2})(?:\s+\$?(?<total>\d[\d,]*\.?\d{0,2}))?\s*$/i,
    /^(?<desc>.+?)\s+(?<qty>\d+(?:\.\d+)?)\s+\$?(?<unit>\d[\d,]*\.?\d{0,2})\s+\$?(?<total>\d[\d,]*\.?\d{0,2})\s*$/i,
    /^(?<qty>\d+(?:\.\d+)?)\s+(?<desc>.+?)\s+\$?(?<unit>\d[\d,]*\.?\d{0,2})(?:\s+\$?(?<total>\d[\d,]*\.?\d{0,2}))?\s*$/i,
    /^(?<desc>.+?)\s+(?<qty>\d+(?:\.\d+)?)\s+\$?(?<total>\d[\d,]*\.?\d{0,2})\s*$/i,
    /^(?<desc>.+?)\s+\$?(?<unit>\d[\d,]*\.?\d{0,2})\s*$/i,
  ];
  for (const pattern of patterns) {
    const match = cleaned.match(pattern);
    if (!match || !match.groups) continue;
    const desc = String(match.groups.desc || '').trim();
    if (!isLikelyItemDescription(desc)) continue;
    const qty = parseQuantity(match.groups.qty || '');
    const unit = parseMoney(match.groups.unit || '');
    const total = parseMoney(match.groups.total || '');
    let finalQty = qty;
    let finalUnit = unit;
    let finalTotal = total;
    if (finalQty !== null && finalUnit !== null && finalTotal === null) {
      finalTotal = finalQty * finalUnit;
    }
    if (finalQty !== null && finalTotal !== null && finalUnit === null && finalQty !== 0) {
      finalUnit = finalTotal / finalQty;
    }
    if (finalQty === null && finalUnit !== null) {
      finalQty = 1;
      if (finalTotal === null) finalTotal = finalUnit;
    }
    return {
      description: desc,
      sku: null,
      qty: finalQty,
      unit_price: finalUnit,
      line_total: finalTotal,
    };
  }
  return null;
}

function extractSkuFromLine(line: string): string | null {
  // Match patterns like "Item #: 7384", "Item# 254896", "SKU: ABC123"
  const match = line.match(/^\s*(?:item\s*#?\s*:?\s*|sku\s*:?\s*)([A-Z0-9-]+)\s*$/i);
  return match ? match[1] : null;
}

function findTotalsStartIndex(lines: string[]): number {
  for (let i = 0; i < lines.length; i++) {
    if (isTotalsIndicator(lines[i])) return i;
  }
  return lines.length;
}

function findItemsStartIndex(lines: string[], totalsStart: number): number | null {
  for (let i = 0; i < totalsStart; i++) {
    const lower = lines[i].toLowerCase();
    const hasDesc = /\b(description|item|product)\b/.test(lower);
    const hasQty = /\b(qty|quantity)\b/.test(lower);
    const hasPrice = /\b(price|amount|total|unit)\b/.test(lower);
    if (hasDesc && hasQty && hasPrice) return i + 1;
    if (parseLineItem(lines[i])) return i;
  }
  return null;
}

function extractReceiptFields(text: string): ParsedReceipt {
  const lines = normalizeReceiptLines(text || '');

  let vendor: string | null = extractVendorFromLabels(lines);
  if (!vendor) {
    for (const line of lines.slice(0, 6)) {
      if (isLikelyVendorLine(line)) { vendor = line; break; }
    }
  }

  let receiptDate: string | null = null;
  const dateLabelRegex = /\b(invoice date|purchase date|order date|date)\b/i;
  for (const line of lines) {
    if (!dateLabelRegex.test(line)) continue;
    receiptDate = extractDateFromLine(line);
    if (receiptDate) break;
  }
  if (!receiptDate) {
    for (const line of lines.slice(0, 20)) {
      receiptDate = extractDateFromLine(line);
      if (receiptDate) break;
    }
  }

  const subtotal = extractLabeledAmount(lines, ['subtotal', 'sub total']);
  const tax = extractLabeledAmount(lines, ['total tax', 'sales tax', 'tax', 'vat', 'gst', 'hst', 'pst'], [/tax id/i]);
  let total = extractLabeledAmount(
    lines,
    ['grand total', 'total due', 'amount due', 'balance due', 'order total', 'total'],
    [/total savings|savings total|subtotal|total\s+tax|tax\s+total/i]
  );

  // Some receipts (like Lowe's) have totals BEFORE line items
  // So we scan ALL lines for potential items, not just before totals
  const lineItems: ParsedLineItem[] = [];
  const usedLines = new Set<number>();
  const scanEnd = lines.length;
  const scanStart = 0;

  for (let i = scanStart; i < scanEnd; i++) {
    if (usedLines.has(i)) continue;
    const line = lines[i];

    // Try single-line parsing first
    const item = parseLineItem(line);
    if (item) {
      lineItems.push(item);
      usedLines.add(i);
      if (lineItems.length >= 200) break;
      continue;
    }

    // Try multi-line: description on current line, price on next line
    // Format: "PRODUCT NAME" followed by "Item #: SKU" and/or "$ 43.96"
    if (isLikelyItemDescription(line) && !isLineItemExcluded(line) && i + 1 < scanEnd) {
      // Look ahead for price line (may be immediately after, or after Item # line)
      let priceLineIdx = -1;
      let price: number | null = null;
      for (let j = i + 1; j < Math.min(i + 4, scanEnd); j++) {
        const priceMatch = lines[j].match(/^\s*\$\s*([0-9][0-9,]*\.?\d{0,2})\s*$/);
        if (priceMatch) {
          price = parseMoney(priceMatch[1]);
          if (price !== null) {
            priceLineIdx = j;
            break;
          }
        }
        // Also check for inline price with qty (e.g., "2 @ 21.98 $ 43.96")
        const inlineMatch = lines[j].match(/^\s*(\d+)\s*@\s*[\d.,]+\s*\$\s*([0-9][0-9,]*\.?\d{0,2})\s*$/);
        if (inlineMatch) {
          price = parseMoney(inlineMatch[2]);
          if (price !== null) {
            priceLineIdx = j;
            break;
          }
        }
      }

      if (price !== null && priceLineIdx > 0) {
        // Look for SKU (Item #) and quantity lines (may be after price line)
        let qty = 1;
        let unitPrice = price;
        let sku: string | null = null;
        for (let j = i + 1; j < Math.min(priceLineIdx + 4, scanEnd); j++) {
          // Check for Item # / SKU line
          const itemSku = extractSkuFromLine(lines[j]);
          if (itemSku) {
            sku = itemSku;
            usedLines.add(j);
            continue;
          }
          // Check for quantity line (e.g., "2 @ 21.98")
          const qtyMatch = lines[j].match(/^\s*(\d+)\s*@\s*([\d.,]+)/);
          if (qtyMatch) {
            qty = parseInt(qtyMatch[1], 10) || 1;
            unitPrice = parseMoney(qtyMatch[2]) || price / qty;
            usedLines.add(j);
          }
        }
        lineItems.push({
          description: line.trim(),
          sku,
          qty,
          unit_price: unitPrice,
          line_total: price,
        });
        usedLines.add(i);
        usedLines.add(priceLineIdx);
        if (lineItems.length >= 200) break;
      }
    }
  }

  let finalSubtotal = subtotal;
  let finalTax = tax;
  let finalTotal = total;
  if (finalTotal === null && finalSubtotal !== null && finalTax !== null) {
    finalTotal = finalSubtotal + finalTax;
  }
  if (finalSubtotal === null && lineItems.length) {
    const sum = lineItems.reduce((acc, item) => acc + (item.line_total || 0), 0);
    finalSubtotal = sum > 0 ? sum : null;
  }
  if (finalTax === null && finalSubtotal !== null && finalTotal !== null) {
    const computedTax = finalTotal - finalSubtotal;
    if (computedTax >= 0) finalTax = computedTax;
  }

  return {
    vendor_name: vendor,
    receipt_date: receiptDate,
    subtotal: finalSubtotal,
    tax: finalTax,
    total: finalTotal,
    line_items: lineItems.slice(0, 200),
  };
}

async function extractPdfText(file: File): Promise<string> {
  try {
    const { getDocument } = await import('https://esm.sh/pdfjs-dist@3.11.174/build/pdf.mjs');
    const data = new Uint8Array(await file.arrayBuffer());
    const loadingTask = getDocument({ data, disableWorker: true });
    const pdf = await loadingTask.promise;
    let output = '';
    for (let i = 1; i <= pdf.numPages; i++) {
      const page = await pdf.getPage(i);
      const content = await page.getTextContent();
      const strings = content.items.map((item: { str?: string }) => item.str || '').join(' ');
      if (strings.trim()) output += strings + '\n';
    }
    return output.trim();
  } catch (err) {
    logger.warn('PDF text extraction failed', { error: err instanceof Error ? err.message : String(err) });
    return '';
  }
}

async function renderPdfPagesToImages(file: File): Promise<Blob[]> {
  if (typeof OffscreenCanvas === 'undefined') return [];
  try {
    const { getDocument } = await import('https://esm.sh/pdfjs-dist@3.11.174/build/pdf.mjs');
    const data = new Uint8Array(await file.arrayBuffer());
    const loadingTask = getDocument({ data, disableWorker: true });
    const pdf = await loadingTask.promise;
    const outputs: Blob[] = [];
    for (let i = 1; i <= pdf.numPages; i++) {
      const page = await pdf.getPage(i);
      const viewport = page.getViewport({ scale: 2 });
      const canvas = new OffscreenCanvas(viewport.width, viewport.height);
      const ctx = canvas.getContext('2d');
      if (!ctx) continue;
      await page.render({ canvasContext: ctx, viewport }).promise;
      const blob = await canvas.convertToBlob({ type: 'image/png' });
      outputs.push(blob);
    }
    return outputs;
  } catch (err) {
    logger.warn('PDF render to image failed', { error: err instanceof Error ? err.message : String(err) });
    return [];
  }
}

async function runOcrOnImage(blob: Blob): Promise<string> {
  try {
    const { createWorker } = await import('https://esm.sh/tesseract.js@4.0.2');
    const worker = createWorker({ logger: () => {} });
    await worker.load();
    await worker.loadLanguage('eng');
    await worker.initialize('eng');
    await worker.setParameters({ tessedit_pageseg_mode: '6' });
    const { data } = await worker.recognize(blob);
    await worker.terminate();
    const text = data?.text || '';
    return String(text).trim();
  } catch (err) {
    logger.warn('OCR failed', { error: err instanceof Error ? err.message : String(err) });
    return '';
  }
}

async function extractReceiptText(
  html: string,
  text: string,
  attachments: File[]
): Promise<{ rawText: string; source: string }>{
  const htmlText = stripHtmlToText(html);
  if (htmlText) return { rawText: htmlText, source: 'email_html' };

  const pdf = attachments.find(f => f.type === 'application/pdf' || f.name.toLowerCase().endsWith('.pdf'));
  if (pdf) {
    const pdfText = await extractPdfText(pdf);
    if (pdfText) return { rawText: pdfText, source: 'email_pdf' };
    const rendered = await renderPdfPagesToImages(pdf);
    if (rendered.length) {
      const parts: string[] = [];
      for (const image of rendered) {
        const ocr = await runOcrOnImage(image);
        if (ocr) parts.push(ocr);
      }
      const combined = parts.join('\\n').trim();
      if (combined) return { rawText: combined, source: 'email_pdf' };
    }
  }

  const image = attachments.find(f => f.type.startsWith('image/'));
  if (image) {
    const ocrText = await runOcrOnImage(image);
    if (ocrText) return { rawText: ocrText, source: 'image_upload' };
  }

  const plain = decodeHtmlEntities(String(text || '').trim());
  if (plain) return { rawText: plain, source: 'email_text' };

  return { rawText: '', source: 'email_text' };
}

function safeJsonParse(value: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function normalizeFingerprintValue(value: string): string {
  return String(value || '').trim().toLowerCase();
}

function normalizeFingerprintText(text: string): string {
  return String(text || '')
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase()
    .slice(0, 4000);
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(digest))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

function getReceiptRetentionDays(tier: string): number {
  const normalized = String(tier || '').trim().toLowerCase();
  if (normalized === 'enterprise') return 365 * 7;
  if (normalized === 'professional' || normalized === 'business') return 365;
  return 0;
}

function getRetentionExpiresAt(days: number): string | null {
  if (!Number.isFinite(days) || days <= 0) return null;
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
}

function sanitizeFileName(name: string): string {
  const raw = String(name || '').trim() || 'attachment';
  const cleaned = raw
    .replace(/[/\\]+/g, '_')
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .slice(0, 180);
  return cleaned || 'attachment';
}

function resolveAttachmentStorageProvider(): AttachmentStorageProvider {
  const provider = String(Deno.env.get('RECEIPT_ATTACHMENT_STORAGE') || '').trim().toLowerCase();
  if (provider === 'external') {
    const externalUrl = String(Deno.env.get('RECEIPT_ATTACHMENT_EXTERNAL_URL') || '').trim();
    if (!externalUrl) {
      logger.warn('Receipt attachment storage set to external without URL; defaulting to supabase.');
      return 'supabase';
    }
    return 'external';
  }
  return 'supabase';
}

async function storeReceiptAttachments(params: {
  supabase: ReturnType<typeof getServiceClient>;
  receiptId: string;
  companyId: string;
  attachments: File[];
  storageProvider: AttachmentStorageProvider;
  retentionExpiresAt: string | null;
  serviceUserId: string;
  requestId: string;
}): Promise<void> {
  const {
    supabase,
    receiptId,
    companyId,
    attachments,
    storageProvider,
    retentionExpiresAt,
    serviceUserId,
    requestId,
  } = params;

  if (!attachments.length) return;

  if (storageProvider === 'external') {
    const externalUrl = String(Deno.env.get('RECEIPT_ATTACHMENT_EXTERNAL_URL') || '').trim();
    if (!externalUrl) return;
    const token = String(Deno.env.get('RECEIPT_ATTACHMENT_EXTERNAL_TOKEN') || '').trim();
    const headers: Record<string, string> = {};
    if (token) headers.Authorization = `Bearer ${token}`;

    for (const file of attachments) {
      const safeName = sanitizeFileName(file.name || '');
      const form = new FormData();
      form.append('file', file, safeName);
      form.append('receipt_id', receiptId);
      form.append('company_id', companyId);
      form.append('file_name', file.name || safeName);
      form.append('content_type', file.type || 'application/octet-stream');
      form.append('byte_size', String(file.size || 0));
      if (retentionExpiresAt) form.append('retention_expires_at', retentionExpiresAt);

      try {
        const res = await fetch(externalUrl, { method: 'POST', headers, body: form });
        const payload = await res.json().catch(() => ({}));
        if (!res.ok || payload?.ok === false) {
          logger.warn('External receipt attachment upload failed', {
            request_id: requestId,
            status: res.status,
            error: payload?.error || payload?.message || 'Upload failed',
            file: file.name || safeName,
          });
          continue;
        }
        const storageUrl = String(payload?.storage_url || payload?.url || '').trim();
        const storageKey = String(payload?.storage_key || payload?.key || payload?.path || '').trim();
        if (!storageUrl && !storageKey) {
          logger.warn('External receipt attachment upload missing storage reference', {
            request_id: requestId,
            file: file.name || safeName,
          });
          continue;
        }
        const { error: insertError } = await supabase
          .from('receipt_attachments')
          .insert({
            receipt_id: receiptId,
            company_id: companyId,
            file_name: file.name || safeName,
            content_type: file.type || null,
            byte_size: file.size || 0,
            storage_provider: 'external',
            storage_path: storageKey || null,
            storage_url: storageUrl || null,
            retention_expires_at: retentionExpiresAt,
            created_by: serviceUserId,
            updated_by: serviceUserId,
          });
        if (insertError) {
          logger.warn('Receipt attachment metadata insert failed', {
            request_id: requestId,
            error: insertError.message,
            file: file.name || safeName,
          });
        }
      } catch (err) {
        logger.warn('External receipt attachment upload failed', {
          request_id: requestId,
          error: err instanceof Error ? err.message : String(err),
          file: file.name || safeName,
        });
      }
    }
    return;
  }

  const bucket = String(Deno.env.get('RECEIPT_ATTACHMENT_BUCKET') || DEFAULT_ATTACHMENT_BUCKET).trim();
  for (const file of attachments) {
    const safeName = sanitizeFileName(file.name || '');
    const objectPath = `${companyId}/${receiptId}/${crypto.randomUUID()}-${safeName}`;
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      const { error: uploadError } = await supabase.storage
        .from(bucket)
        .upload(objectPath, bytes, {
          contentType: file.type || 'application/octet-stream',
          upsert: false,
        });
      if (uploadError) {
        logger.warn('Receipt attachment upload failed', {
          request_id: requestId,
          error: uploadError.message,
          file: file.name || safeName,
        });
        continue;
      }
      const { error: insertError } = await supabase
        .from('receipt_attachments')
        .insert({
          receipt_id: receiptId,
          company_id: companyId,
          file_name: file.name || safeName,
          content_type: file.type || null,
          byte_size: file.size || 0,
          storage_provider: 'supabase',
          storage_bucket: bucket,
          storage_path: objectPath,
          retention_expires_at: retentionExpiresAt,
          created_by: serviceUserId,
          updated_by: serviceUserId,
        });
      if (insertError) {
        logger.warn('Receipt attachment metadata insert failed', {
          request_id: requestId,
          error: insertError.message,
          file: file.name || safeName,
        });
      }
    } catch (err) {
      logger.warn('Receipt attachment upload failed', {
        request_id: requestId,
        error: err instanceof Error ? err.message : String(err),
        file: file.name || safeName,
      });
    }
  }
}

// POST /inbound/receipt-email
export async function handleInboundReceiptEmail(
  request: Request,
  _auth: AuthContext | null,
  _params: Record<string, string>,
  requestId: string
): Promise<Response> {
  try {
    const rawBytes = new Uint8Array(await request.clone().arrayBuffer());
    if (rawBytes.length > MAX_BODY_BYTES) {
      return jsonResponse({ ok: false, error: 'Payload too large', request_id: requestId }, 413);
    }

    // Authentication: token-based (for Inbound Parse) or signature-based (for Event Webhooks)
    const inboundToken = Deno.env.get('SENDGRID_INBOUND_TOKEN') || '';
    const publicKeyConfigured = Boolean(
      Deno.env.get('SENDGRID_INBOUND_PUBLIC_KEY') || Deno.env.get('SENDGRID_WEBHOOK_PUBLIC_KEY')
    );

    if (inboundToken) {
      // Token-based auth: check URL query parameter
      const url = new URL(request.url);
      const providedToken = url.searchParams.get('token') || '';
      if (!providedToken || providedToken !== inboundToken) {
        logger.warn('Inbound receipt token mismatch', { request_id: requestId });
        return jsonResponse({ ok: false, error: 'Unauthorized', request_id: requestId }, 401);
      }
    } else if (publicKeyConfigured) {
      // Signature-based auth: verify SendGrid signature
      const signatureOk = await verifySendgridSignature(request, rawBytes);
      if (!signatureOk) {
        return jsonResponse({ ok: false, error: 'Unauthorized', request_id: requestId }, 401);
      }
    } else {
      // No auth configured
      return jsonResponse({ ok: false, error: 'Inbound auth not configured', request_id: requestId }, 500);
    }

    const form = await request.formData();
    const html = String(form.get('html') || '');
    const text = String(form.get('text') || '');
    const subject = String(form.get('subject') || '').trim();
    const from = String(form.get('from') || '').trim();
    const to = String(form.get('to') || '').trim();
    const envelopeRaw = String(form.get('envelope') || '').trim();
    const messageId = String(form.get('Message-Id') || form.get('message-id') || '').trim();

    const envelope = envelopeRaw ? safeJsonParse(envelopeRaw) : null;
    const envelopeTo = envelope && Array.isArray((envelope as Record<string, unknown>).to)
      ? (envelope as Record<string, unknown>).to as string[]
      : [];

    const recipients = [
      ...extractEmails(to),
      ...extractEmails(envelopeTo.join(',')),
    ];

    const domain = Deno.env.get('INBOUND_RECEIPT_DOMAIN') || DEFAULT_DOMAIN;
    const legacyDomain = Deno.env.get('RECEIPT_FORWARD_DOMAIN') || '';
    const slug = extractSlugFromRecipients(recipients, domain)
      || (legacyDomain ? extractSlugFromRecipients(recipients, legacyDomain) : null)
      || (domain !== LEGACY_DOMAIN ? extractSlugFromRecipients(recipients, LEGACY_DOMAIN) : null);
    if (!slug) {
      return jsonResponse({ ok: false, error: 'No valid receipt address found', request_id: requestId }, 400);
    }

    const attachments: File[] = [];
    const attachmentMeta: Array<{ name: string; content_type: string; size: number }> = [];
    for (const [key, value] of form.entries()) {
      if (value instanceof File) {
        attachments.push(value);
        attachmentMeta.push({
          name: value.name || key,
          content_type: value.type || 'application/octet-stream',
          size: value.size || 0,
        });
      }
    }

    const serviceUserId = Deno.env.get('RECEIPT_INGESTION_USER_ID') || '';
    if (!serviceUserId) {
      return jsonResponse({ ok: false, error: 'Receipt ingestion user not configured', request_id: requestId }, 500);
    }

    const supabase = getServiceClient();
    const { data: company, error: companyError } = await supabase
      .from('companies')
      .select('id,slug,is_active,base_subscription_tier')
      .eq('slug', slug)
      .maybeSingle();

    if (companyError) {
      logger.error('Company lookup failed', { request_id: requestId, error: companyError.message });
      return jsonResponse({ ok: false, error: 'Company lookup failed', request_id: requestId }, 500);
    }

    if (!company || !company.is_active) {
      return jsonResponse({ ok: false, error: 'Company not found or inactive', request_id: requestId }, 404);
    }

    let effectiveTier = '';
    try {
      const { data: tierData, error: tierError } = await supabase.rpc('get_company_tier', {
        p_company_id: company.id,
      });
      if (tierError) {
        logger.warn('Company tier lookup failed', { request_id: requestId, error: tierError.message });
      } else {
        const row = Array.isArray(tierData) ? tierData[0] : tierData;
        if (row && typeof row.effective_tier === 'string') {
          effectiveTier = row.effective_tier;
        }
      }
    } catch (err) {
      logger.warn('Company tier lookup failed', { request_id: requestId, error: err instanceof Error ? err.message : String(err) });
    }
    if (!effectiveTier) {
      const baseTier = company && typeof company === 'object' && 'base_subscription_tier' in company
        ? String((company as { base_subscription_tier?: string }).base_subscription_tier || '').trim()
        : '';
      effectiveTier = baseTier;
    }
    const normalizedTier = String(effectiveTier || '').trim().toLowerCase();
    const tierAllowsReceiptIngestion = ['professional', 'business', 'enterprise'].includes(normalizedTier);
    const receiptStatus = tierAllowsReceiptIngestion ? 'draft' : 'blocked_by_plan';
    const retentionDays = getReceiptRetentionDays(normalizedTier);
    const retentionExpiresAt = getRetentionExpiresAt(retentionDays);
    const allowAttachmentProcessing = retentionDays > 0;

    const { rawText, source } = await extractReceiptText(
      html,
      text,
      allowAttachmentProcessing ? attachments : []
    );
    const parsed = extractReceiptFields(rawText);

    const { data: receiptNumber, error: receiptNumErr } = await supabase
      .rpc('generate_receipt_number', { p_company_id: company.id });

    if (receiptNumErr || !receiptNumber) {
      logger.error('Receipt number generation failed', { request_id: requestId, error: receiptNumErr?.message });
      return jsonResponse({ ok: false, error: 'Failed to create receipt', request_id: requestId }, 500);
    }

    const totalValue = Number(parsed.total);
    const totalText = Number.isFinite(totalValue) ? totalValue.toFixed(2) : '';
    const fingerprintInput = [
      company.id,
      normalizeFingerprintValue(parsed.vendor_name || ''),
      normalizeFingerprintValue(parsed.receipt_date || ''),
      totalText,
      normalizeFingerprintText(rawText || ''),
    ].join('|');
    const receiptFingerprint = fingerprintInput ? await sha256Hex(fingerprintInput) : '';
    let possibleDuplicate = false;
    if (receiptFingerprint) {
      const windowDays = Number(Deno.env.get('RECEIPT_DEDUPE_WINDOW_DAYS') || DEFAULT_DEDUPE_WINDOW_DAYS);
      const windowMs = Number.isFinite(windowDays) ? windowDays * 24 * 60 * 60 * 1000 : DEFAULT_DEDUPE_WINDOW_DAYS * 24 * 60 * 60 * 1000;
      const cutoff = new Date(Date.now() - windowMs).toISOString();
      try {
        const { data: dupes, error: dupErr } = await supabase
          .from('receipts')
          .select('id')
          .eq('company_id', company.id)
          .eq('receipt_fingerprint', receiptFingerprint)
          .gte('created_at', cutoff)
          .limit(1);
        if (dupErr) {
          logger.warn('Receipt duplicate check failed', { request_id: requestId, error: dupErr.message });
        } else if (Array.isArray(dupes) && dupes.length) {
          possibleDuplicate = true;
        }
      } catch (err) {
        logger.warn('Receipt duplicate check failed', { request_id: requestId, error: err instanceof Error ? err.message : String(err) });
      }
    }

    const emailMetadata = {
      from,
      to,
      subject,
      message_id: messageId,
      received_at: new Date().toISOString(),
      envelope,
      attachments: attachmentMeta,
    };

    const insertPayload = {
      company_id: company.id,
      receipt_number: receiptNumber,
      status: receiptStatus,
      vendor_name: parsed.vendor_name,
      receipt_date: parsed.receipt_date,
      subtotal: parsed.subtotal,
      tax: parsed.tax,
      total: parsed.total,
      raw_receipt_text: rawText || null,
      parsed_line_items: parsed.line_items,
      receipt_source: source,
      email_metadata: emailMetadata,
      receipt_fingerprint: receiptFingerprint || null,
      possible_duplicate: possibleDuplicate,
      created_at: new Date().toISOString(),
      created_by: serviceUserId,
      updated_at: new Date().toISOString(),
      updated_by: serviceUserId,
    };

    const { data: receiptRow, error: insertError } = await supabase
      .from('receipts')
      .insert(insertPayload)
      .select('id,receipt_number')
      .single();

    if (insertError || !receiptRow) {
      logger.error('Receipt insert failed', { request_id: requestId, error: insertError?.message });
      return jsonResponse({ ok: false, error: 'Failed to create receipt', request_id: requestId }, 500);
    }

    if (allowAttachmentProcessing && attachments.length) {
      const storageProvider = resolveAttachmentStorageProvider();
      await storeReceiptAttachments({
        supabase,
        receiptId: receiptRow.id,
        companyId: company.id,
        attachments,
        storageProvider,
        retentionExpiresAt,
        serviceUserId,
        requestId,
      });
    }

    try {
      await supabase.rpc('log_receipt_audit_event', {
        p_event_name: 'receipt_ingested_email',
        p_receipt_id: receiptRow.id,
        p_purchase_order_id: null,
        p_company_id: company.id,
        p_actor_user_id: serviceUserId,
        p_metadata: {
          source,
          subject,
          slug,
          attachment_count: attachmentMeta.length,
        },
      });
    } catch (err) {
      logger.warn('Receipt audit log failed', { error: err instanceof Error ? err.message : String(err) });
    }

    return jsonResponse({
      ok: true,
      receipt_id: receiptRow.id,
      receipt_number: receiptRow.receipt_number,
      status: receiptStatus,
    }, 201);
  } catch (err) {
    logger.error('Inbound receipt handler failed', {
      request_id: requestId,
      error: err instanceof Error ? err.message : String(err),
    });
    return jsonResponse({ ok: false, error: 'Failed to process receipt', request_id: requestId }, 500);
  }
}
