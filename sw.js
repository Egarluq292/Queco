// Preferencias · service worker
// Guarda solo la propia app (no los mensajes) para poder abrirla sin red,
// y muestra los avisos de mensajes nuevos. Siempre intenta la red primero,
// así las actualizaciones llegan solas.
const CACHE = 'susurro-v70';
const ARCHIVOS = ['./', './index.html', './manifest.json', './icono-192.png', './icono-512.png'];
const ES_IOS = /iPhone|iPad|iPod/.test(self.navigator.userAgent);

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARCHIVOS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return; // Supabase: sin tocar
  e.respondWith(
    fetch(e.request, { cache: 'no-cache' })
      .then(r => { const copia = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copia)); return r; })
      .catch(() => caches.match(e.request, { ignoreSearch: true }))
  );
});

// Aviso de mensaje nuevo: no lleva contenido, solo «Hay novedades»
self.addEventListener('push', e => {
  e.waitUntil((async () => {
    const ventanas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const abierta = ventanas.some(v => v.visibilityState === 'visible');
    const marca = marcarEntrega(); // «recibido»: a qué hora llegó el aviso (no dice nada de leerlo)
    if (abierta && !ES_IOS) { await marca; return; } // si estás mirando la app, no hace falta avisar
    await self.registration.showNotification('Preferencias', {
      body: 'Hay novedades',
      icon: 'icono-192.png',
      badge: 'icono-192.png',
      tag: 'novedades',
      renotify: true,
      vibrate: [120, 60, 120],
      timestamp: Date.now()
    });
    await marca;
  })());
});

// Datos mínimos que deja la app para poder apuntar la entrega con la app cerrada
function leerAcceso() {
  return new Promise(res => {
    const r = indexedDB.open('preferencias-sw', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('datos');
    r.onerror = () => res(null);
    r.onsuccess = () => {
      try {
        const q = r.result.transaction('datos').objectStore('datos').get('acceso');
        q.onsuccess = () => res(q.result || null); q.onerror = () => res(null);
      } catch { res(null); }
    };
  });
}
async function marcarEntrega() {
  try {
    const a = await leerAcceso();
    if (!a) return;
    const h = { 'Content-Type': 'application/json', apikey: a.k };
    if (a.k.startsWith('eyJ')) h.Authorization = 'Bearer ' + a.k;
    await fetch(a.url + '/rest/v1/rpc/marcar_entrega', {
      method: 'POST', headers: h, cache: 'no-store', referrerPolicy: 'no-referrer',
      body: JSON.stringify({ p_sala: a.sala, p_disp: a.disp, ...(a.llave ? { p_llave: a.llave } : {}) })
    });
  } catch {}
}

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil((async () => {
    const ventanas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const v of ventanas) if ('focus' in v) return v.focus();
    return self.clients.openWindow('./');
  })());
});
