// Service worker: solo para notificaciones (no guarda nada en caché).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'José Carrizo e Hijos', {
    body: d.body || '',
    icon: 'icon-192.png',
    badge: 'img/badge.png',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    vibrate: [80, 40, 80],
    data: { url: d.url || '' }
  }));
});

const pagina = u => { const p = new URL(u).pathname; return p.endsWith('/') ? p + 'index.html' : p; };

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const rel = (e.notification.data && e.notification.data.url) || '';
  e.waitUntil((async () => {
    const lista = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const url = new URL(rel || './', self.registration.scope).href;
    const misma = lista.find(c => pagina(c.url) === pagina(url)) || (!rel && lista[0]);
    if (misma) {
      await misma.focus();
      if (rel) misma.postMessage({ tipo: 'abrir', url });
      return;
    }
    return self.clients.openWindow(url);
  })());
});
