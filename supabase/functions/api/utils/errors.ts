// ============================================================================
// APPLICATION ERRORS
// ============================================================================

export type ErrorCode =
  | 'VALIDATION_ERROR'
  | 'AUTHENTICATION_ERROR'
  | 'AUTHORIZATION_ERROR'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'RATE_LIMITED'
  | 'DEPENDENCY_CONFLICT'
  | 'INTERNAL_ERROR'
  | 'SERVICE_UNAVAILABLE';

/**
 * Base application error
 */
export class AppError extends Error {
  constructor(
    public readonly code: ErrorCode,
    message: string,
    public readonly statusCode: number,
    public readonly details?: Record<string, unknown>
  ) {
    super(message);
    this.name = 'AppError';
  }
}

/**
 * Validation error with field-level details
 */
export class ValidationError extends AppError {
  constructor(
    message: string,
    public readonly errors: Array<{ field: string; message: string; code: string }>
  ) {
    super('VALIDATION_ERROR', message, 400, { errors });
    this.name = 'ValidationError';
  }
}

/**
 * Authentication error (missing/invalid token)
 */
export class AuthenticationError extends AppError {
  constructor(message: string = 'Authentication required') {
    super('AUTHENTICATION_ERROR', message, 401, {
      hint: 'Ensure Authorization header contains a valid Bearer token',
    });
    this.name = 'AuthenticationError';
  }
}

/**
 * Authorization error (valid token but insufficient permissions)
 */
export class AuthorizationError extends AppError {
  constructor(message: string = 'You do not have permission to perform this action') {
    super('AUTHORIZATION_ERROR', message, 403);
    this.name = 'AuthorizationError';
  }
}

/**
 * Resource not found
 */
export class NotFoundError extends AppError {
  constructor(resource: string = 'Resource') {
    super('NOT_FOUND', `${resource} not found`, 404);
    this.name = 'NotFoundError';
  }
}

/**
 * Conflict error (e.g., duplicate SKU)
 */
export class ConflictError extends AppError {
  constructor(message: string, field?: string) {
    super('CONFLICT', message, 409, field ? { field } : undefined);
    this.name = 'ConflictError';
  }
}

/**
 * Rate limit exceeded
 */
export class RateLimitError extends AppError {
  constructor(
    public readonly retryAfter: number,
    public readonly limit: number,
    public readonly resetAt: number
  ) {
    super('RATE_LIMITED', `Rate limit exceeded. Retry after ${retryAfter} seconds.`, 429, {
      limit,
      window_seconds: 60,
      retry_after: retryAfter,
    });
    this.name = 'RateLimitError';
  }
}

/**
 * Dependency conflict (can't delete due to references)
 */
export class DependencyConflictError extends AppError {
  constructor(
    message: string,
    public readonly blockingResources: Array<{ type: string; id: string; description: string }>
  ) {
    super('DEPENDENCY_CONFLICT', message, 409, { blocking_resources: blockingResources });
    this.name = 'DependencyConflictError';
  }
}
