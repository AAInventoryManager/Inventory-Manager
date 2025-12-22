// ============================================================================
// STRUCTURED LOGGING
// ============================================================================

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogContext {
  request_id?: string;
  user_id?: string;
  company_id?: string;
  method?: string;
  path?: string;
  status?: number;
  duration_ms?: number;
  [key: string]: unknown;
}

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context: LogContext;
}

function log(level: LogLevel, message: string, context: LogContext = {}): void {
  const entry: LogEntry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    context,
  };
  
  // Output as single-line JSON for log aggregation
  const output = JSON.stringify(entry);
  
  switch (level) {
    case 'error':
      console.error(output);
      break;
    case 'warn':
      console.warn(output);
      break;
    default:
      console.log(output);
  }
}

export const logger = {
  debug: (message: string, context?: LogContext) => log('debug', message, context),
  info: (message: string, context?: LogContext) => log('info', message, context),
  warn: (message: string, context?: LogContext) => log('warn', message, context),
  error: (message: string, context?: LogContext) => log('error', message, context),
  
  /**
   * Log an HTTP request/response cycle
   */
  request: (
    request: Request,
    response: Response,
    context: LogContext & { duration_ms: number }
  ): void => {
    const url = new URL(request.url);
    const level: LogLevel = response.status >= 500 ? 'error' :
                            response.status >= 400 ? 'warn' : 'info';
    
    log(level, `${request.method} ${url.pathname} ${response.status}`, {
      method: request.method,
      path: url.pathname,
      status: response.status,
      ...context,
    });
  },
};
