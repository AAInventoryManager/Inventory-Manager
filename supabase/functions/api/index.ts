// ============================================================================
// INVENTORY MANAGER API - EDGE FUNCTION ENTRY POINT
// ============================================================================
//
// This is the main router for the Inventory Manager REST API.
// It handles all incoming requests and routes them to appropriate handlers.
//
// Request Flow:
// 1. CORS handling (preflight + headers)
// 2. Request ID generation
// 3. Authentication (except /health)
// 4. Rate limiting
// 5. Route matching
// 6. Input validation (in handlers)
// 7. Business logic
// 8. Response formatting
//
// ============================================================================

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

// Middleware
import { corsMiddleware, handlePreflight, getCorsHeaders } from './middleware/cors.ts';
import { authenticate, type AuthContext } from './middleware/auth.ts';
import { checkRateLimit, getRateLimitHeaders } from './middleware/rate-limit.ts';
import { generateRequestId } from './middleware/request-id.ts';

// Handlers
import { handleHealth } from './handlers/health.ts';
import { 
  handleListInventory,
  handleGetInventory,
  handleCreateInventory,
  handleUpdateInventory,
  handleDeleteInventory,
  handleBulkCreateInventory,
  handleAdjustInventory,
} from './handlers/inventory.ts';
import { handleLowStock } from './handlers/reports.ts';
import { handleInboundReceiptEmail } from './handlers/inbound_receipt_email.ts';

// Utils
import { AppError, AuthenticationError } from './utils/errors.ts';
import { errorResponse, internalErrorResponse, jsonResponse } from './utils/responses.ts';
import { logger } from './utils/logger.ts';

// ============================================================================
// TYPES
// ============================================================================

interface RouteMatch {
  handler: RouteHandler;
  params: Record<string, string>;
}

type RouteHandler = (
  request: Request,
  auth: AuthContext | null,
  params: Record<string, string>,
  requestId: string
) => Promise<Response>;

interface Route {
  method: string;
  pattern: RegExp;
  paramNames: string[];
  handler: RouteHandler;
  requiresAuth: boolean;
}

// ============================================================================
// ROUTE DEFINITIONS
// ============================================================================

const routes: Route[] = [
  // Health check - no auth required
  {
    method: 'GET',
    pattern: /^\/health$/,
    paramNames: [],
    handler: handleHealth,
    requiresAuth: false,
  },

  // Inbound receipt email (SendGrid Inbound Parse) - no auth, signature required
  {
    method: 'POST',
    pattern: /^\/inbound\/receipt-email$/,
    paramNames: [],
    handler: handleInboundReceiptEmail,
    requiresAuth: false,
  },
  
  // Inventory CRUD
  {
    method: 'GET',
    pattern: /^\/v1\/inventory$/,
    paramNames: [],
    handler: handleListInventory,
    requiresAuth: true,
  },
  {
    method: 'POST',
    pattern: /^\/v1\/inventory$/,
    paramNames: [],
    handler: handleCreateInventory,
    requiresAuth: true,
  },
  {
    method: 'GET',
    pattern: /^\/v1\/inventory\/([0-9a-f-]{36})$/,
    paramNames: ['id'],
    handler: handleGetInventory,
    requiresAuth: true,
  },
  {
    method: 'PATCH',
    pattern: /^\/v1\/inventory\/([0-9a-f-]{36})$/,
    paramNames: ['id'],
    handler: handleUpdateInventory,
    requiresAuth: true,
  },
  {
    method: 'DELETE',
    pattern: /^\/v1\/inventory\/([0-9a-f-]{36})$/,
    paramNames: ['id'],
    handler: handleDeleteInventory,
    requiresAuth: true,
  },
  
  // Bulk operations
  {
    method: 'POST',
    pattern: /^\/v1\/inventory\/bulk$/,
    paramNames: [],
    handler: handleBulkCreateInventory,
    requiresAuth: true,
  },
  
  // Quantity adjustments
  {
    method: 'POST',
    pattern: /^\/v1\/inventory\/([0-9a-f-]{36})\/adjust$/,
    paramNames: ['id'],
    handler: handleAdjustInventory,
    requiresAuth: true,
  },
  
  // Reports
  {
    method: 'GET',
    pattern: /^\/v1\/inventory\/low-stock$/,
    paramNames: [],
    handler: handleLowStock,
    requiresAuth: true,
  },
];

// ============================================================================
// ROUTE MATCHING
// ============================================================================

function matchRoute(method: string, pathname: string): RouteMatch | null {
  for (const route of routes) {
    if (route.method !== method) continue;
    
    const match = pathname.match(route.pattern);
    if (!match) continue;
    
    // Extract named parameters
    const params: Record<string, string> = {};
    route.paramNames.forEach((name, index) => {
      params[name] = match[index + 1];
    });
    
    return { handler: route.handler, params };
  }
  
  return null;
}

function findRouteConfig(method: string, pathname: string): Route | null {
  for (const route of routes) {
    if (route.method === method && route.pattern.test(pathname)) {
      return route;
    }
  }
  return null;
}

// ============================================================================
// MAIN REQUEST HANDLER
// ============================================================================

async function handleRequest(request: Request): Promise<Response> {
  const startTime = performance.now();
  const requestId = generateRequestId();
  const url = new URL(request.url);
  
  // Remove the /functions/v1/api prefix that Supabase adds
  const pathname = url.pathname.replace(/^\/functions\/v1\/api/, '') || '/';
  
  let auth: AuthContext | null = null;
  let response: Response;
  
  try {
    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return handlePreflight(request);
    }
    
    // Match route
    const routeMatch = matchRoute(request.method, pathname);
    const routeConfig = findRouteConfig(request.method, pathname);
    
    if (!routeMatch || !routeConfig) {
      response = jsonResponse({
        error: {
          code: 'NOT_FOUND',
          message: `No route matches ${request.method} ${pathname}`,
        },
        request_id: requestId,
        timestamp: new Date().toISOString(),
      }, 404);
      
      return addResponseHeaders(request, response, requestId);
    }
    
    // Authentication (if required)
    if (routeConfig.requiresAuth) {
      try {
        auth = await authenticate(request);
      } catch (error) {
        if (error instanceof AuthenticationError) {
          response = errorResponse(error, requestId);
          return addResponseHeaders(request, response, requestId);
        }
        throw error;
      }
      
      // Rate limiting (only for authenticated requests)
      const rateLimit = await checkRateLimit(auth.user.id, 'standard');
      const rateLimitHeaders = getRateLimitHeaders(rateLimit);
      
      // Execute handler
      response = await routeMatch.handler(request, auth, routeMatch.params, requestId);
      
      // Add rate limit headers to response
      rateLimitHeaders.forEach((value, key) => {
        response.headers.set(key, value);
      });
    } else {
      // Execute handler without auth
      response = await routeMatch.handler(request, null, routeMatch.params, requestId);
    }
    
  } catch (error) {
    // Handle known errors
    if (error instanceof AppError) {
      response = errorResponse(error, requestId);
    } else {
      // Unknown error - log and return generic message
      logger.error('Unhandled error', {
        request_id: requestId,
        error: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
      });
      response = internalErrorResponse(requestId);
    }
  }
  
  // Add common headers and log
  response = addResponseHeaders(request, response, requestId);
  
  // Log request
  const duration = performance.now() - startTime;
  logger.request(request, response, {
    request_id: requestId,
    user_id: auth?.user.id,
    company_id: auth?.user.company_id,
    duration_ms: Math.round(duration * 100) / 100,
  });
  
  return response;
}

// ============================================================================
// RESPONSE HELPERS
// ============================================================================

function addResponseHeaders(
  request: Request, 
  response: Response, 
  requestId: string
): Response {
  // Clone response to modify headers
  const newHeaders = new Headers(response.headers);
  
  // Add CORS headers
  const corsHeaders = getCorsHeaders(request);
  corsHeaders.forEach((value, key) => {
    newHeaders.set(key, value);
  });
  
  // Add request ID
  newHeaders.set('X-Request-Id', requestId);
  
  // Security headers
  newHeaders.set('X-Content-Type-Options', 'nosniff');
  newHeaders.set('X-Frame-Options', 'DENY');
  
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

// ============================================================================
// SERVER ENTRY POINT
// ============================================================================

serve(handleRequest, {
  onListen({ port, hostname }) {
    logger.info(`API server running`, { hostname, port });
  },
  onError(error) {
    logger.error('Server error', { 
      error: error instanceof Error ? error.message : String(error) 
    });
    return internalErrorResponse('server-error');
  },
});
