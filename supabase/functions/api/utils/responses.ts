// ============================================================================
// RESPONSE UTILITIES
// ============================================================================

import { AppError, ValidationError, RateLimitError } from './errors.ts';

/**
 * Standard JSON response
 */
export function jsonResponse<T>(
  data: T,
  status: number = 200,
  headers: Headers = new Headers()
): Response {
  headers.set('Content-Type', 'application/json');
  
  return new Response(JSON.stringify(data), {
    status,
    headers,
  });
}

/**
 * Paginated list response with metadata
 */
export function paginatedResponse<T>(
  data: T[],
  meta: {
    total: number;
    limit: number;
    offset: number;
    filtered_total?: number;
  },
  headers: Headers = new Headers()
): Response {
  return jsonResponse({
    data,
    meta: {
      ...meta,
      has_more: meta.offset + data.length < meta.total,
    },
  }, 200, headers);
}

/**
 * No content response (204)
 */
export function noContentResponse(headers: Headers = new Headers()): Response {
  return new Response(null, { status: 204, headers });
}

/**
 * Created response with Location header (201)
 */
export function createdResponse<T>(
  data: T,
  location: string,
  headers: Headers = new Headers()
): Response {
  headers.set('Location', location);
  return jsonResponse({ data }, 201, headers);
}

/**
 * Error response from AppError
 */
export function errorResponse(
  error: AppError,
  requestId: string,
  headers: Headers = new Headers()
): Response {
  // Add rate limit headers for rate limit errors
  if (error instanceof RateLimitError) {
    headers.set('Retry-After', error.retryAfter.toString());
    headers.set('X-RateLimit-Limit', error.limit.toString());
    headers.set('X-RateLimit-Remaining', '0');
    headers.set('X-RateLimit-Reset', error.resetAt.toString());
  }
  
  const body: Record<string, unknown> = {
    error: {
      code: error.code,
      message: error.message,
    },
    request_id: requestId,
    timestamp: new Date().toISOString(),
  };
  
  // Add validation errors if present
  if (error instanceof ValidationError) {
    (body.error as Record<string, unknown>).errors = error.errors;
  }
  
  // Add other details
  if (error.details) {
    Object.assign(body.error as Record<string, unknown>, error.details);
  }
  
  return jsonResponse(body, error.statusCode, headers);
}

/**
 * Internal error response (500) - hides implementation details
 */
export function internalErrorResponse(requestId: string): Response {
  return jsonResponse({
    error: {
      code: 'INTERNAL_ERROR',
      message: 'An unexpected error occurred. Please try again or contact support.',
      details: {
        support_reference: 'Contact support with request_id',
      },
    },
    request_id: requestId,
    timestamp: new Date().toISOString(),
  }, 500);
}
