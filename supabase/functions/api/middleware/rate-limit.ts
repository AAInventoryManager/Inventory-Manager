// ============================================================================
// RATE LIMITING MIDDLEWARE
// ============================================================================

import { RateLimitError } from '../utils/errors.ts';

interface RateLimitConfig {
  windowMs: number;
  maxRequests: number;
  burstLimit: number;
}

const RATE_LIMITS: Record<string, RateLimitConfig> = {
  standard: { windowMs: 60000, maxRequests: 100, burstLimit: 150 },
  premium: { windowMs: 60000, maxRequests: 500, burstLimit: 750 },
  enterprise: { windowMs: 60000, maxRequests: 2000, burstLimit: 3000 },
};

// In-memory store for rate limiting
// NOTE: For production with multiple instances, use database or Redis
const rateLimitStore = new Map<string, { count: number; resetAt: number }>();

export interface RateLimitResult {
  remaining: number;
  limit: number;
  resetAt: number;
}

/**
 * Check and update rate limit for a user
 */
export async function checkRateLimit(
  userId: string,
  tier: string = 'standard'
): Promise<RateLimitResult> {
  const config = RATE_LIMITS[tier] || RATE_LIMITS.standard;
  const key = `${userId}:${tier}`;
  const now = Date.now();
  
  let entry = rateLimitStore.get(key);
  
  // Reset if window has passed
  if (!entry || now >= entry.resetAt) {
    entry = {
      count: 0,
      resetAt: now + config.windowMs,
    };
  }
  
  entry.count++;
  rateLimitStore.set(key, entry);
  
  const remaining = Math.max(0, config.maxRequests - entry.count);
  const resetAtSeconds = Math.floor(entry.resetAt / 1000);
  
  // Check burst limit
  if (entry.count > config.burstLimit) {
    const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
    throw new RateLimitError(retryAfter, config.maxRequests, resetAtSeconds);
  }
  
  return {
    remaining,
    limit: config.maxRequests,
    resetAt: resetAtSeconds,
  };
}

/**
 * Get rate limit headers for response
 */
export function getRateLimitHeaders(rateLimit: RateLimitResult): Headers {
  const headers = new Headers();
  headers.set('X-RateLimit-Limit', rateLimit.limit.toString());
  headers.set('X-RateLimit-Remaining', rateLimit.remaining.toString());
  headers.set('X-RateLimit-Reset', rateLimit.resetAt.toString());
  return headers;
}

/**
 * Cleanup expired entries (call periodically)
 */
export function cleanupRateLimitStore(): void {
  const now = Date.now();
  for (const [key, entry] of rateLimitStore.entries()) {
    if (now >= entry.resetAt) {
      rateLimitStore.delete(key);
    }
  }
}

// Cleanup every 5 minutes
setInterval(cleanupRateLimitStore, 5 * 60 * 1000);
