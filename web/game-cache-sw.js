// Only public, versioned game assets are cached. Account/API responses never enter CacheStorage.
const CACHE = 'xiuxian-game-resources-v1';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  const request = event.request, url = new URL(request.url);
  if (request.method !== 'GET' || request.headers.has('Range') || url.origin !== self.location.origin ||
      !/^\/web-[a-f0-9]{40}\/(?:index\.(?:pck|wasm|js|png|icon\.png|apple-touch-icon\.png)|loading\/[^/]+\.(?:png|mp4))$/.test(url.pathname)) return;
  event.respondWith((async () => {
    let cache;
    const send = async data => { const client = await self.clients.get(event.clientId); client?.postMessage(data); };
    try {
      cache = await caches.open(CACHE);
      const hit = await cache.match(request);
      if (hit) { await send({type:'resource-cache-hit', bytes:Number(hit.headers.get('Content-Length')) || 0}); return hit; }
    } catch { await send({type:'resource-cache-unavailable'}); }
    const response = await fetch(request);
    if (cache && response.ok && response.status === 200) {
      const copy = response.clone();
      event.waitUntil(cache.put(request, copy).catch(() => send({type:'resource-cache-unavailable'})));
    }
    return response;
  })());
});
