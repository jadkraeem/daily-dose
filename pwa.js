// =========================================================
// Daily Dose — تفعيل التطبيق (PWA)
// 1) تسجيل عامل الخدمة (sw.js)
// 2) بطاقة صغيرة «ثبّت التطبيق» للكاشير والمطبخ وبطاقة الولاء (لا تظهر بالمنيو)
//    - أندرويد/كروم: زر «ثبّت» يفتح نافذة التثبيت الرسمية
//    - آيفون: تلميح «مشاركة ← إضافة إلى الشاشة الرئيسية»
//    - ما بتغطي الأزرار: الصفحة بتاخد مسافة تحت وقت تظهر، وبتختفي لحالها بعد 12 ثانية
// =========================================================
(function () {
  'use strict';

  if ('serviceWorker' in navigator) {
    addEventListener('load', function () {
      navigator.serviceWorker.register('sw.js').catch(function () { /* المتصفح لا يدعم أو منعه: الموقع يعمل عادي */ });
    });
  }

  var page = (location.pathname.split('/').pop() || 'index.html');
  var PAGES = {
    'casher.html':  { title: 'ثبّت الكاشير كتطبيق', sub: 'بيفتح بكبسة من شاشة الجهاز' },
    'kitchen.html': { title: 'ثبّت المطبخ كتطبيق', sub: 'بيفتح بكبسة من شاشة الجهاز' },
    'loyalty.html': { title: 'احفظ بطاقتك على جوالك', sub: 'بتفتح بطاقتك بكبسة وحدة' }
  };
  var info = PAGES[page];
  var installed = (window.matchMedia && matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true;
  if (!info || installed) return;

  var KEY = 'dailydose-install-hint-' + page;
  function snoozedUntil() { try { return Number(localStorage.getItem(KEY + '-until') || 0); } catch (e) { return 0; } }
  function snooze(days) { try { localStorage.setItem(KEY + '-until', String(Date.now() + days * 864e5)); } catch (e) { /* تجاهل */ } }
  // توافق مع المفتاح القديم (آخر إغلاق) = 7 أيام
  try { var old = Number(localStorage.getItem(KEY) || 0); if (old && Date.now() - old < 7 * 864e5) return; } catch (e) { /* تجاهل */ }
  if (Date.now() < snoozedUntil()) return;

  var css = document.createElement('style');
  css.textContent =
    '.mb-install{position:fixed;z-index:9000;left:50%;bottom:calc(12px + env(safe-area-inset-bottom));transform:translate(-50%,0);'
    + 'width:min(420px,calc(100% - 24px));display:flex;align-items:center;gap:10px;padding:10px 10px 10px 12px;border-radius:18px;'
    + 'background:#032e24f2;color:#f7f1e7;box-shadow:0 12px 30px -10px rgba(0,0,0,.6),inset 0 0 0 1px #0b6b51;'
    + 'font:600 14px/1.45 Cairo,system-ui,sans-serif;direction:rtl;animation:mbIn .35s ease both;-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)}'
    + '.mb-install.out{animation:mbOut .3s ease both}'
    + '.mb-ic{font-size:22px;flex-shrink:0}'
    + '.mb-tx{flex:1;min-width:0}'
    + '.mb-tx b{display:block;color:#e3c88a;font-weight:800;font-size:14px}'
    + '.mb-tx small{display:block;color:#e9ddca;font-size:12px;opacity:.9}'
    + '.mb-install button{border:0;cursor:pointer;font:inherit;border-radius:999px;flex-shrink:0}'
    + '.mb-go{background:#c9a45c;color:#032e24;font-weight:800;padding:8px 16px}'
    + '.mb-x{background:transparent;color:#e9ddca;width:34px;height:34px;font-size:16px}'
    + 'body.mb-space{padding-bottom:calc(84px + env(safe-area-inset-bottom))}'
    + 'body.mb-space .main-content{padding-bottom:calc(96px + env(safe-area-inset-bottom))}'
    + '@keyframes mbIn{from{opacity:0;transform:translate(-50%,16px)}}'
    + '@keyframes mbOut{to{opacity:0;transform:translate(-50%,16px)}}'
    + '@media (prefers-reduced-motion:reduce){.mb-install,.mb-install.out{animation:none}}'
    + '@media print{.mb-install{display:none}}';

  var el = null, timer = null;
  function hide(days) {
    if (!el) return;
    snooze(days);
    clearTimeout(timer);
    var x = el; el = null;
    x.classList.add('out');
    setTimeout(function () { x.remove(); document.body.classList.remove('mb-space'); }, 300);
  }
  function show(sub, onGo) {
    if (el || document.querySelector('.mb-install')) return;
    document.head.appendChild(css);
    el = document.createElement('div');
    el.className = 'mb-install';
    el.setAttribute('role', 'status');
    el.innerHTML = '<span class="mb-ic" aria-hidden="true">📲</span><div class="mb-tx"><b></b><small></small></div>'
      + (onGo ? '<button type="button" class="mb-go">ثبّت</button>' : '')
      + '<button type="button" class="mb-x" aria-label="إغلاق">✕</button>';
    el.querySelector('b').textContent = info.title;
    el.querySelector('small').textContent = sub;
    el.querySelector('.mb-x').onclick = function () { hide(7); };
    if (onGo) el.querySelector('.mb-go').onclick = function () { hide(30); onGo(); };
    document.body.appendChild(el);
    document.body.classList.add('mb-space');
    timer = setTimeout(function () { hide(1); }, 12000); // بيختفي لحاله، وبيرجع بعد يوم
  }

  // أندرويد / كروم / إيدج: نافذة التثبيت الرسمية
  addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    var promptEvent = e;
    show(info.sub, function () { promptEvent.prompt(); });
  });

  // آيفون/آيباد: تلميح يدوي (بصفحة البطاقة في شرح جاهز تحت البطاقة، فما منكرره)
  var ua = navigator.userAgent || '';
  var isIOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  if (isIOS && page !== 'loyalty.html') {
    addEventListener('load', function () {
      setTimeout(function () { show('اكبس مشاركة ⬆️ ← «إضافة إلى الشاشة الرئيسية»'); }, 2500);
    });
  }
})();
