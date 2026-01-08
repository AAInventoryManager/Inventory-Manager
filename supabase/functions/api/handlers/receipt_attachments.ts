// ============================================================================
// RECEIPT ATTACHMENT HANDLERS
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import type { AuthContext } from '../middleware/auth.ts';
import { AuthorizationError, NotFoundError, ValidationError } from '../utils/errors.ts';
import { jsonResponse, noContentResponse } from '../utils/responses.ts';
import { isValidUUID } from '../utils/validate.ts';
import { logger } from '../utils/logger.ts';

const DEFAULT_ATTACHMENT_BUCKET = 'receipt-attachments';
const SIGNED_URL_TTL_SECONDS = 60 * 10;

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

async function fetchAttachmentForUser(
  auth: AuthContext,
  receiptId: string,
  attachmentId: string,
  opts: { includeExpired?: boolean } = {}
) {
  const { data, error } = await auth.supabase
    .from('receipt_attachments')
    .select('id,receipt_id,company_id,file_name,storage_provider,storage_bucket,storage_path,storage_url,retention_expires_at')
    .eq('id', attachmentId)
    .eq('receipt_id', receiptId)
    .is('deleted_at', null)
    .maybeSingle();
  if (error) {
    throw new Error(`Database error: ${error.message}`);
  }
  if (!data) {
    throw new NotFoundError('Receipt attachment');
  }
  if (!opts.includeExpired && data.retention_expires_at) {
    const expiresAt = new Date(data.retention_expires_at);
    if (!Number.isNaN(expiresAt.getTime()) && expiresAt <= new Date()) {
      throw new NotFoundError('Receipt attachment');
    }
  }
  return data as {
    id: string;
    receipt_id: string;
    company_id: string;
    file_name: string | null;
    storage_provider: string | null;
    storage_bucket: string | null;
    storage_path: string | null;
    storage_url: string | null;
    retention_expires_at: string | null;
  };
}

// ============================================================================
// GET /v1/receipts/:receipt_id/attachments
// ============================================================================

export async function handleListReceiptAttachments(
  _request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();

  const receiptId = params.receipt_id;
  if (!isValidUUID(receiptId)) {
    throw new ValidationError('Invalid receipt ID', [
      { field: 'receipt_id', message: 'Must be a valid UUID', code: 'invalid_format' },
    ]);
  }

  const nowIso = new Date().toISOString();
  const { data, error } = await auth.supabase
    .from('receipt_attachments')
    .select('id,receipt_id,file_name,content_type,byte_size,storage_provider,retention_expires_at,created_at')
    .eq('receipt_id', receiptId)
    .is('deleted_at', null)
    .or(`retention_expires_at.is.null,retention_expires_at.gt.${nowIso}`)
    .order('created_at', { ascending: false });

  if (error) {
    throw new Error(`Database error: ${error.message}`);
  }

  return jsonResponse({ data: data || [] });
}

// ============================================================================
// GET /v1/receipts/:receipt_id/attachments/:attachment_id/download
// ============================================================================

export async function handleReceiptAttachmentDownload(
  _request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  _requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();

  const receiptId = params.receipt_id;
  const attachmentId = params.attachment_id;
  if (!isValidUUID(receiptId) || !isValidUUID(attachmentId)) {
    throw new ValidationError('Invalid attachment request', [
      { field: 'receipt_id', message: 'Must be a valid UUID', code: 'invalid_format' },
      { field: 'attachment_id', message: 'Must be a valid UUID', code: 'invalid_format' },
    ]);
  }

  const attachment = await fetchAttachmentForUser(auth, receiptId, attachmentId);
  const provider = String(attachment.storage_provider || 'supabase').toLowerCase();

  if (provider === 'external') {
    const url = String(attachment.storage_url || '').trim();
    if (!url) {
      throw new NotFoundError('Attachment download');
    }
    return jsonResponse({ data: { url } });
  }

  const bucket = String(attachment.storage_bucket || DEFAULT_ATTACHMENT_BUCKET).trim();
  const path = String(attachment.storage_path || '').trim();
  if (!path) {
    throw new NotFoundError('Attachment download');
  }

  const service = getServiceClient();
  const { data, error } = await service.storage
    .from(bucket)
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);

  if (error || !data?.signedUrl) {
    throw new Error(`Failed to create signed URL: ${error?.message || 'Unknown error'}`);
  }

  return jsonResponse({ data: { url: data.signedUrl } });
}

// ============================================================================
// DELETE /v1/receipts/:receipt_id/attachments/:attachment_id
// ============================================================================

export async function handleDeleteReceiptAttachment(
  _request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  requestId: string
): Promise<Response> {
  if (!auth) throw new AuthorizationError();

  const receiptId = params.receipt_id;
  const attachmentId = params.attachment_id;
  if (!isValidUUID(receiptId) || !isValidUUID(attachmentId)) {
    throw new ValidationError('Invalid attachment request', [
      { field: 'receipt_id', message: 'Must be a valid UUID', code: 'invalid_format' },
      { field: 'attachment_id', message: 'Must be a valid UUID', code: 'invalid_format' },
    ]);
  }

  const attachment = await fetchAttachmentForUser(auth, receiptId, attachmentId, { includeExpired: true });

  const { data: allowed, error: permError } = await auth.supabase.rpc('check_permission', {
    p_company_id: attachment.company_id,
    p_permission_key: 'company:edit_settings',
  });
  if (permError) {
    throw new Error(`Permission check failed: ${permError.message}`);
  }
  if (!allowed) {
    throw new AuthorizationError();
  }

  const provider = String(attachment.storage_provider || 'supabase').toLowerCase();
  const service = getServiceClient();

  if (provider === 'external') {
    const deleteUrl = String(Deno.env.get('RECEIPT_ATTACHMENT_EXTERNAL_DELETE_URL') || '').trim();
    const token = String(Deno.env.get('RECEIPT_ATTACHMENT_EXTERNAL_TOKEN') || '').trim();
    if (deleteUrl) {
      const headers: Record<string, string> = { 'content-type': 'application/json' };
      if (token) headers.Authorization = `Bearer ${token}`;
      try {
        const res = await fetch(deleteUrl, {
          method: 'POST',
          headers,
          body: JSON.stringify({
            attachment_id: attachment.id,
            receipt_id: attachment.receipt_id,
            storage_key: attachment.storage_path,
            storage_url: attachment.storage_url,
          }),
        });
        if (!res.ok) {
          logger.warn('External receipt attachment delete failed', {
            request_id: requestId,
            status: res.status,
            attachment_id: attachment.id,
          });
        }
      } catch (err) {
        logger.warn('External receipt attachment delete failed', {
          request_id: requestId,
          error: err instanceof Error ? err.message : String(err),
          attachment_id: attachment.id,
        });
      }
    }
  } else {
    const bucket = String(attachment.storage_bucket || DEFAULT_ATTACHMENT_BUCKET).trim();
    const path = String(attachment.storage_path || '').trim();
    if (path) {
      const { error: storageError } = await service.storage
        .from(bucket)
        .remove([path]);
      if (storageError) {
        logger.warn('Receipt attachment storage delete failed', {
          request_id: requestId,
          error: storageError.message,
          attachment_id: attachment.id,
        });
      }
    }
  }

  const now = new Date().toISOString();
  const { error: updateError } = await service
    .from('receipt_attachments')
    .update({
      deleted_at: now,
      deleted_by: auth.user.id,
      updated_at: now,
      updated_by: auth.user.id,
    })
    .eq('id', attachment.id);

  if (updateError) {
    throw new Error(`Failed to delete attachment: ${updateError.message}`);
  }

  return noContentResponse();
}
