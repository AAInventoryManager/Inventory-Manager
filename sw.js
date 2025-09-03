/* Don's Inventory Tracker – offline cache for app + parsers */
const CACHE = 'inv-cache-v6';
const PRECACHE = [
  // Your entry HTML (update if you rename file)
  './index.html',
  './manifest.webmanifest'
];

// Third-party parser scripts we may fetch at runtime
const RUNTIME_URLS = [
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js',
  'https://cdn.jsdelivr.net/npm/mammoth@1.6.0/mammoth.browser.min.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll(PRECACHE))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Network-first for third-party parser scripts; cache-first for same-origin
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Cache parser scripts once fetched
  if (RUNTIME_URLS.some(u => event.request.url.startsWith(u))) {
    event.respondWith((async () => {
      try {
        const net = await fetch(event.request);
        const cache = await caches.open(CACHE);
        cache.put(event.request, net.clone());
        return net;
      } catch {
        const hit = await caches.match(event.request);
        return hit || Response.error();
      }
    })());
    return;
  }

  // Same-origin: prefer cache, fall back to network
  if (url.origin === location.origin) {
    event.respondWith(
      caches.match(event.request).then(cached => cached || fetch(event.request))
    );
  }
});
