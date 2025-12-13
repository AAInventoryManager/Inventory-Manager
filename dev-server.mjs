import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

const PROJECT_ROOT = process.cwd();

function parseArgs(argv) {
  const out = { host: '127.0.0.1', port: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--host') out.host = argv[++i] || out.host;
    else if (a === '--port') out.port = Number(argv[++i]);
    else if (a === '--help' || a === '-h') out.help = true;
  }
  return out;
}

async function loadDotEnvIfPresent() {
  const envPath = path.join(PROJECT_ROOT, '.env');
  try {
    const raw = await fsp.readFile(envPath, 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      let val = trimmed.slice(eq + 1).trim();
      if (!key) continue;
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch {
    // No .env file — ignore.
  }
}

function json(res, status, body, extraHeaders = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  res.end(payload);
}

function readBody(req, maxBytes = 100_000) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(Object.assign(new Error('Request too large'), { code: 'ETOOLARGE' }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function looksLikeEmail(email) {
  const s = String(email || '').trim();
  if (!s) return false;
  if (s.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

function getAllowedDomains() {
  const raw = String(process.env.ALLOWED_RECIPIENT_DOMAINS || '').trim();
  if (!raw) return null;
  const parts = raw
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return parts.length ? new Set(parts) : null;
}

async function sendViaMailtrapApi({ to, subject, text }) {
  const token = String(process.env.MAILTRAP_API_TOKEN || process.env.MAILTRAP_TOKEN || '').trim();
  const fromEmail = String(process.env.MAILTRAP_FROM_EMAIL || process.env.MAIL_FROM_EMAIL || '').trim();
  const fromName = String(process.env.MAILTRAP_FROM_NAME || process.env.MAIL_FROM_NAME || "Don's Inventory Tracker").trim();
  const baseUrl = String(process.env.MAILTRAP_API_BASE_URL || 'https://send.api.mailtrap.io/api/send').trim();

  if (!token) throw Object.assign(new Error('MAILTRAP_API_TOKEN is not configured'), { status: 501 });
  if (!fromEmail) throw Object.assign(new Error('MAILTRAP_FROM_EMAIL is not configured'), { status: 501 });

  const resp = await fetch(baseUrl, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      from: { email: fromEmail, name: fromName },
      to: [{ email: to }],
      subject,
      text,
    }),
  });

  const raw = await resp.text();
  let parsed = null;
  try {
    parsed = raw ? JSON.parse(raw) : null;
  } catch {
    parsed = null;
  }

  if (!resp.ok) {
    const msg = (parsed && (parsed.message || parsed.error)) ? String(parsed.message || parsed.error) : `Mailtrap error (${resp.status})`;
    throw Object.assign(new Error(msg), { status: resp.status, details: parsed || raw });
  }

  return parsed || { ok: true };
}

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.webmanifest':
      return 'application/manifest+json; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.png':
      return 'image/png';
    case '.ico':
      return 'image/x-icon';
    case '.svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

async function serveStatic(req, res, urlPathname) {
  const safePath = decodeURIComponent(urlPathname);
  if (safePath.includes('\0')) return false;

  const requestPath = safePath === '/' ? '/index.html' : safePath;
  const diskPath = path.join(PROJECT_ROOT, requestPath);
  const resolved = path.resolve(diskPath);
  if (!resolved.startsWith(path.resolve(PROJECT_ROOT))) {
    json(res, 403, { ok: false, error: 'Forbidden' });
    return true;
  }

  let stat;
  try {
    stat = await fsp.stat(resolved);
  } catch {
    return false;
  }
  if (!stat.isFile()) return false;

  const ct = contentTypeFor(resolved);
  const isHtml = resolved.endsWith('.html');
  const isSw = resolved.endsWith(path.sep + 'sw.js');
  const cacheControl = (isHtml || isSw) ? 'no-cache' : 'public, max-age=3600';

  res.writeHead(200, {
    'content-type': ct,
    'content-length': stat.size,
    'cache-control': cacheControl,
  });
  fs.createReadStream(resolved).pipe(res);
  return true;
}

async function main() {
  await loadDotEnvIfPresent();

  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: node dev-server.mjs [--host 127.0.0.1] [--port 5173]');
    process.exit(0);
  }

  const port = Number.isFinite(args.port) && args.port > 0 ? args.port : Number(process.env.PORT || 5173);
  const host = String(process.env.HOST || args.host || '127.0.0.1');

  const allowedDomains = getAllowedDomains();

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
      const pathname = url.pathname || '/';

      // Basic health check.
      if (req.method === 'GET' && pathname === '/api/health') {
        json(res, 200, { ok: true });
        return;
      }

      // API: Send order email via Mailtrap.
      if (pathname === '/api/send-order') {
        if (req.method === 'OPTIONS') {
          res.writeHead(204, {
            'access-control-allow-origin': '*',
            'access-control-allow-methods': 'POST, OPTIONS',
            'access-control-allow-headers': 'content-type',
            'access-control-max-age': '86400',
          });
          res.end();
          return;
        }
        if (req.method !== 'POST') {
          json(res, 405, { ok: false, error: 'Method not allowed' }, { allow: 'POST, OPTIONS' });
          return;
        }

        let bodyRaw = '';
        try {
          bodyRaw = await readBody(req);
        } catch (e) {
          if (e && e.code === 'ETOOLARGE') {
            json(res, 413, { ok: false, error: 'Request too large' });
            return;
          }
          throw e;
        }

        let body = null;
        try {
          body = bodyRaw ? JSON.parse(bodyRaw) : null;
        } catch {
          json(res, 400, { ok: false, error: 'Invalid JSON' });
          return;
        }

        const to = String(body?.to || body?.toEmail || body?.email || '').trim();
        const subject = String(body?.subject || 'Materials Order').trim();
        const text = String(body?.text || body?.body || '').trim();

        if (!looksLikeEmail(to)) {
          json(res, 400, { ok: false, error: 'Invalid recipient email' });
          return;
        }

        if (allowedDomains) {
          const domain = to.split('@').pop().toLowerCase();
          if (!allowedDomains.has(domain)) {
            json(res, 403, { ok: false, error: 'Recipient domain not allowed' });
            return;
          }
        }

        if (!subject || subject.length > 200) {
          json(res, 400, { ok: false, error: 'Invalid subject' });
          return;
        }
        if (!text || text.length > 20_000) {
          json(res, 400, { ok: false, error: 'Invalid body' });
          return;
        }

        try {
          const result = await sendViaMailtrapApi({ to, subject, text });
          json(res, 200, { ok: true, result });
        } catch (e) {
          const status = Number.isFinite(e?.status) ? e.status : 500;
          json(res, status, { ok: false, error: e?.message || 'Send failed', details: e?.details });
        }
        return;
      }

      // Static assets.
      if (req.method === 'GET' || req.method === 'HEAD') {
        const served = await serveStatic(req, res, pathname);
        if (served) return;
      }

      json(res, 404, { ok: false, error: 'Not found' });
    } catch (e) {
      json(res, 500, { ok: false, error: e?.message || 'Server error' });
    }
  });

  server.listen(port, host, () => {
    console.log(`Dev server: http://${host}:${port}/`);
    console.log('Email API:   POST /api/send-order');
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

