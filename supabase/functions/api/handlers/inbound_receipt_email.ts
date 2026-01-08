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

function stripHtmlToText(html: string): string {
  const raw = String(html || '').trim();
  if (!raw) return '';
  try {
    const parser = new DOMParser();
    const doc = parser.parseFromString(raw, 'text/html');
    const text = doc?.body?.innerText || doc?.body?.textContent || '';
    return String(text || '').replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  } catch {
    return raw
      .replace(/<style[\s\S]*?<\/style>/gi, '\n')
      .replace(/<script[\s\S]*?<\/script>/gi, '\n')
      .replace(/<br\s*\/?\s*>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
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
  const tryDate = new Date(raw);
  if (!Number.isNaN(tryDate.getTime())) return tryDate.toISOString().slice(0, 10);
  return null;
}

function extractReceiptFields(text: string): ParsedReceipt {
  const lines = String(text || '')
    .split(/\r?\n/)
    .map(l => l.trim())
    .filter(Boolean);

  let vendor: string | null = null;
  for (const line of lines.slice(0, 6)) {
    if (/receipt|invoice|statement/i.test(line)) continue;
    if (line.length >= 2 && line.length <= 60) { vendor = line; break; }
  }

  const datePatterns = [
    /\b(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})\b/,
    /\b(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\b/,
    /\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{2,4}\b/i
  ];
  let receiptDate: string | null = null;
  for (const line of lines) {
    for (const pattern of datePatterns) {
      const match = line.match(pattern);
      if (match) {
        receiptDate = parseDate(match[1]);
        if (receiptDate) break;
      }
    }
    if (receiptDate) break;
  }

  const findLabelValue = (label: string): number | null => {
    const regex = new RegExp(`${label}\\s*[:\-]?\\s*\$?([0-9,]+(?:\\.[0-9]{2})?)`, 'i');
    for (const line of lines) {
      const match = line.match(regex);
      if (match) return parseMoney(match[1]);
    }
    return null;
  };

  const subtotal = findLabelValue('subtotal');
  const tax = findLabelValue('tax');
  let total = findLabelValue('total');
  if (total === null) total = findLabelValue('amount due');

  const lineItems: ParsedLineItem[] = [];
  const linePattern = /^(.*?)[\s\t]+(\d{1,4})\s*(?:x)?\s*\$?([0-9,]+(?:\.[0-9]{2})?)\s*$/i;
  for (const line of lines) {
    const match = line.match(linePattern);
    if (!match) continue;
    const desc = match[1]?.trim() || '';
    const qty = Number.parseInt(match[2], 10);
    const price = parseMoney(match[3]);
    if (!desc || !Number.isFinite(qty)) continue;
    lineItems.push({
      description: desc,
      qty: qty,
      unit_price: price,
      line_total: price !== null ? price * qty : null,
    });
  }

  return {
    vendor_name: vendor,
    receipt_date: receiptDate,
    subtotal,
    tax,
    total,
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

  const plain = String(text || '').trim();
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

    const publicKeyConfigured = Boolean(
      Deno.env.get('SENDGRID_INBOUND_PUBLIC_KEY') || Deno.env.get('SENDGRID_WEBHOOK_PUBLIC_KEY')
    );
    if (!publicKeyConfigured) {
      return jsonResponse({ ok: false, error: 'SendGrid signature key not configured', request_id: requestId }, 500);
    }

    const signatureOk = await verifySendgridSignature(request, rawBytes);
    if (!signatureOk) {
      return jsonResponse({ ok: false, error: 'Unauthorized', request_id: requestId }, 401);
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
