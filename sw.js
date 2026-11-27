// =========================================================
// Daily Dose — عامل الخدمة (Service Worker) للتطبيق
// الاستراتيجية: الشبكة أولاً.
//   - مع الإنترنت: كل ملف يُجلب من السيرفر (آخر نسخة دائماً)، وتُحفظ نسخة احتياطية.
//   - بدون إنترنت: تُعرض آخر نسخة محفوظة من الصفحات والملفات.
// لا يلمس طلبات Supabase ولا الخطوط ولا المساعد (نطاقات أخرى) ولا أي طلب غير GET.
// عند تغيير منطق هذا الملف: غيّر رقم النسخة حتى تُحذف النسخ القديمة.
// =========================================================
const CACHE = 'dailydose-v9';

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok && res.type === 'basic') {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
        }
        return res;
      })
      .catch(async () => {
        const isPage = req.mode === 'navigate';
        const cached = await caches.match(req, { ignoreSearch: isPage });
        if (cached) return cached;
        if (isPage) {
          return new Response(
            '<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            + '<title>لا يوجد اتصال</title><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#032e24;color:#f7f1e7;font-family:system-ui,sans-serif;text-align:center;padding:24px">'
            + '<div><div style="font-family:Playfair Display,Georgia,serif;font-weight:700;font-size:44px;color:#c9a45c;line-height:1">Daily Dose</div><div style="font-family:Cairo,system-ui,sans-serif;font-weight:700;font-size:11px;letter-spacing:.32em;color:#c9a45c;margin-top:6px">CAFE &amp; MORE</div><h2 style="margin:12px 0 6px">لا يوجد اتصال بالإنترنت</h2><p style="color:#c9a45c">تحقق من الشبكة ثم أعد فتح التطبيق.</p></div></body></html>',
            { headers: { 'Content-Type': 'text/html; charset=utf-8' } },
          );
        }
        return Response.error();
      }),
  );
});
