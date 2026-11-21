// Retire the former long-download worker. The page now manages CacheStorage itself.
// No fetch handler: uncached resources use the browser network stack without a worker lifetime limit.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
