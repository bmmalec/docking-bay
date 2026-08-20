const CACHE = "launcher-shell-v5";
const SHELL = [
  "./project-launcher.html",
  "./project-launcher.js",
  "./launcher-manifest.webmanifest",
  "./launcher-icon.svg",
];
const FRESH = ["./projects.json", "./launcher.config.json"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // never touch cross-origin requests

  const isFresh = FRESH.some((path) => url.pathname.endsWith(path.replace("./", "/")));

  if (isFresh) {
    // network-first, fall back to cache when offline
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((cache) => cache.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // cache-first for the app shell
  event.respondWith(
    caches.match(req).then((cached) => cached || fetch(req))
  );
});
