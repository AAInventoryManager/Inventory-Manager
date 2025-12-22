// ============================================================================
// VALIDATION UTILITIES
// ============================================================================

import { z, ZodError, ZodSchema, ZodIssueCode } from 'https://deno.land/x/zod@v3.22.4/mod.ts';
import { ValidationError } from './errors.ts';

/**
 * Validate data against a Zod schema
 * Throws ValidationError with formatted errors if validation fails
 */
export function validate<T>(schema: ZodSchema<T>, data: unknown): T {
  try {
    return schema.parse(data);
  } catch (error) {
    if (error instanceof ZodError) {
      const formattedErrors = error.errors.map((err) => ({
        field: err.path.join('.') || 'body',
        message: err.message,
        code: zodIssueCodeToErrorCode(err.code),
      }));
      
      throw new ValidationError('Request validation failed', formattedErrors);
    }
    throw error;
  }
}

/**
 * Validate query parameters from URL
 */
export function validateQuery<T>(
  schema: ZodSchema<T>,
  url: URL
): T {
  const params: Record<string, string> = {};
  url.searchParams.forEach((value, key) => {
    params[key] = value;
  });
  return validate(schema, params);
}

/**
 * Validate JSON request body
 */
export async function validateBody<T>(
  schema: ZodSchema<T>,
  request: Request
): Promise<T> {
  let body: unknown;
  
  try {
    const text = await request.text();
    if (!text) {
      throw new ValidationError('Request body is required', [
        { field: 'body', message: 'Request body cannot be empty', code: 'required' }
      ]);
    }
    body = JSON.parse(text);
  } catch (error) {
    if (error instanceof ValidationError) throw error;
    throw new ValidationError('Invalid JSON in request body', [
      { field: 'body', message: 'Request body must be valid JSON', code: 'invalid_format' }
    ]);
  }
  
  return validate(schema, body);
}

/**
 * Map Zod issue codes to our error codes
 */
function zodIssueCodeToErrorCode(code: ZodIssueCode): string {
  const mapping: Record<string, string> = {
    invalid_type: 'type_error',
    invalid_literal: 'invalid_format',
    invalid_string: 'invalid_format',
    too_small: 'min_length',
    too_big: 'max_length',
    invalid_enum_value: 'invalid_format',
    unrecognized_keys: 'invalid_format',
    custom: 'validation_error',
  };
  return mapping[code] || 'validation_error';
}

/**
 * Validate UUID format
 */
export function isValidUUID(value: string): boolean {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}
