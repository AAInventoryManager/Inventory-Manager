// ============================================================================
// REQUEST ID MIDDLEWARE
// ============================================================================

/**
 * Generate a unique request ID for tracing
 * Format: req_<uuid>
 */
export function generateRequestId(): string {
  return `req_${crypto.randomUUID()}`;
}

/**
 * Extract request ID from headers or generate new one
 */
export function getOrGenerateRequestId(request: Request): string {
  const existingId = request.headers.get('X-Request-Id');
  
  if (existingId && /^req_[0-9a-f-]{36}$/.test(existingId)) {
    return existingId;
  }
  
  return generateRequestId();
}
