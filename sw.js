'use strict';
// Versioned cache name (bump this when you change cached assets)
const CACHE = 'inv-cache-v15';
// Core assets to pre-cache (add more files here if you split CSS/JS)
const ASSETS = [
  './',
  './assets/oakley/icon/icon-192.png',
  './assets/oakley/icon/icon-512.png',
  './assets/oakley/icon/icon-maskable.png',
  './assets/oakley/logo/oakley-logo-square.png',
  './index.html',
  './manifest.webmanifest?v=5'
];

// Take control immediately on install / activate
self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(ASSETS)).catch(() => {})
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
    try {
      const clis = await self.clients.matchAll({ type: 'window' });
      clis.forEach(c => c.postMessage({ type: 'SW_ACTIVATED', cache: CACHE }));
    } catch (_) {}
  })());
});

// Optional: accept a manual skipWaiting message from clients
self.addEventListener('message', (event) => {
  if (!event || !event.data) return;
  if (event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

// Cache-first for GET; bypass for non-GET (POST/PUT/DELETE)
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // let network handle writes

  // Only handle same-origin requests; let cross-origin (e.g., Supabase API) bypass
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  const accept = req.headers.get('accept') || '';
  const isHTML = req.mode === 'navigate' || accept.includes('text/html');

  if (isHTML) {
    // Network-first for HTML: ensures latest index loads without cache bumps
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      try {
        const res = await fetch(req);
        if (res && res.status === 200 && (res.type === 'basic' || res.type === 'cors')) {
          cache.put(req, res.clone());
        }
        return res;
      } catch (err) {
        // Fallback to cached index or the specific request if present
        return (await cache.match('./index.html')) || (await cache.match(req)) || Response.error();
      }
    })());
    return;
  }

  // Cache-first for non-HTML assets
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req);
    if (cached) return cached;
    try {
      const res = await fetch(req);
      if (res && res.status === 200 && (res.type === 'basic' || res.type === 'cors')) {
        cache.put(req, res.clone());
      }
      return res;
    } catch (err) {
      return cached || Response.error();
    }
  })());
});
