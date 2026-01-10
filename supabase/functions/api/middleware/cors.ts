// ============================================================================
// CORS MIDDLEWARE
// ============================================================================

const ALLOWED_ORIGINS = [
  'http://localhost:3000',
  'http://localhost:5173',
  'http://localhost:8080',
  'http://127.0.0.1:3000',
  'http://127.0.0.1:5173',
  'http://127.0.0.1:8080',
  'https://inventory.modulus-software.com',
  // Add production domains here
];

const ALLOW_ALL_ORIGINS = Deno.env.get('ENVIRONMENT') === 'development';

export interface CorsConfig {
  allowedOrigins: string[];
  allowedMethods: string[];
  allowedHeaders: string[];
  exposedHeaders: string[];
  maxAge: number;
  credentials: boolean;
}

const defaultConfig: CorsConfig = {
  allowedOrigins: ALLOWED_ORIGINS,
  allowedMethods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: [
    'Authorization',
    'Content-Type',
    'Idempotency-Key',
    'X-Request-Id',
  ],
  exposedHeaders: [
    'X-RateLimit-Limit',
    'X-RateLimit-Remaining',
    'X-RateLimit-Reset',
    'X-Request-Id',
    'Location',
  ],
  maxAge: 86400,
  credentials: true,
};

export function getCorsHeaders(
  request: Request,
  config: CorsConfig = defaultConfig
): Headers {
  const headers = new Headers();
  const origin = request.headers.get('Origin');

  const isAllowed = ALLOW_ALL_ORIGINS || 
    (origin && config.allowedOrigins.includes(origin));

  if (isAllowed && origin) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
  }

  headers.set('Access-Control-Allow-Methods', config.allowedMethods.join(', '));
  headers.set('Access-Control-Allow-Headers', config.allowedHeaders.join(', '));
  headers.set('Access-Control-Expose-Headers', config.exposedHeaders.join(', '));
  headers.set('Access-Control-Max-Age', config.maxAge.toString());

  return headers;
}

export function handlePreflight(request: Request): Response {
  const corsHeaders = getCorsHeaders(request);
  return new Response(null, { status: 204, headers: corsHeaders });
}

export function withCors(request: Request, response: Response): Response {
  const corsHeaders = getCorsHeaders(request);
  const newHeaders = new Headers(response.headers);
  corsHeaders.forEach((value, key) => newHeaders.set(key, value));

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

export function corsMiddleware(
  handler: (request: Request) => Promise<Response>
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') {
      return handlePreflight(request);
    }
    const response = await handler(request);
    return withCors(request, response);
  };
}
