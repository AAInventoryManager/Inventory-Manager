'use strict';
// Versioned cache name (bump this when you change cached assets)
const CACHE = 'inv-cache-v9';
// Core assets to pre-cache (add more files here if you split CSS/JS)
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest?v=2',
  './favicon.ico'
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
  })());
});

// Cache-first for GET; bypass for non-GET (POST/PUT/DELETE)
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // let network handle writes

  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req);
    if (cached) return cached;

    try {
      const res = await fetch(req);
      // Cache only successful same-origin responses
      if (res && res.status === 200 && (res.type === 'basic' || res.type === 'cors')) {
        cache.put(req, res.clone());
      }
      return res;
    } catch (err) {
      // If offline and no cache, fail gracefully
      return cached || Response.error();
    }
  })());
});
