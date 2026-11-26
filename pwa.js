// =========================================================
// Daily Dose — تفعيل التطبيق (PWA)
// 1) تسجيل عامل الخدمة (sw.js)
// 2) زر "ثبّت التطبيق" للموظفين فقط (الكاشير والمطبخ)، لا يظهر للزبائن في المنيو
//    - أندرويد/كروم: زر يفتح نافذة التثبيت الرسمية
//    - آيفون: تلميح «مشاركة ← إضافة إلى الشاشة الرئيسية»
// =========================================================
(function () {
  'use strict';

  if ('serviceWorker' in navigator) {
    addEventListener('load', function () {
      navigator.serviceWorker.register('sw.js').catch(function () { /* المتصفح لا يدعم أو منعه: الموقع يعمل عادي */ });
    });
  }

  var page = (location.pathname.split('/').pop() || 'index.html');
  var isStaffPage = page === 'casher.html' || page === 'kitchen.html';
  var installed = (window.matchMedia && matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true;
  if (!isStaffPage || installed) return;

  var KEY = 'dailydose-install-hint';
  function dismissedRecently() {
    try { return Date.now() - Number(localStorage.getItem(KEY) || 0) < 7 * 864e5; } catch (e) { return false; }
  }
  function remember() { try { localStorage.setItem(KEY, String(Date.now())); } catch (e) { /* تجاهل */ } }
  if (dismissedRecently()) return;

  var css = document.createElement('style');
  css.textContent =
    '.mb-install{position:fixed;z-index:9000;left:50%;bottom:16px;transform:translateX(-50%);display:flex;align-items:center;gap:10px;'
    + 'max-width:calc(100% - 24px);padding:8px 8px 8px 14px;border-radius:999px;background:#032e24;color:#f7f1e7;'
    + 'box-shadow:0 10px 30px -8px rgba(0,0,0,.6),inset 0 0 0 1px #0b6b51;font:600 14px/1.4 Cairo,system-ui,sans-serif;direction:rtl}'
    + '.mb-install b{color:#e3c88a}'
    + '.mb-install button{border:0;cursor:pointer;font:inherit;border-radius:999px;padding:7px 14px}'
    + '.mb-install .mb-go{background:#c9a45c;color:#032e24;font-weight:800}'
    + '.mb-install .mb-x{background:transparent;color:#e9ddca;padding:7px 10px}'
    + '@media print{.mb-install{display:none}}';

  function show(html, onGo) {
    if (document.querySelector('.mb-install')) return;
    document.head.appendChild(css);
    var el = document.createElement('div');
    el.className = 'mb-install';
    el.setAttribute('role', 'status');
    el.innerHTML = html + (onGo ? '<button type="button" class="mb-go">ثبّت</button>' : '')
      + '<button type="button" class="mb-x" aria-label="إغلاق">✕</button>';
    el.querySelector('.mb-x').onclick = function () { remember(); el.remove(); };
    if (onGo) el.querySelector('.mb-go').onclick = function () { onGo(el); };
    document.body.appendChild(el);
  }

  // أندرويد / كروم / إيدج: نافذة التثبيت الرسمية
  addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    var promptEvent = e;
    show('📲 ثبّت <b>' + (page === 'kitchen.html' ? 'المطبخ' : 'الكاشير') + '</b> كتطبيق على هذا الجهاز', function (el) {
      el.remove();
      promptEvent.prompt();
      promptEvent.userChoice.finally(remember);
    });
  });

  // آيفون/آيباد (سفاري لا يدعم زر التثبيت): تلميح يدوي
  var ua = navigator.userAgent || '';
  var isIOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  if (isIOS) {
    addEventListener('load', function () {
      setTimeout(function () {
        show('📲 للتثبيت كتطبيق: اضغط <b>مشاركة ⬆️</b> ثم <b>«إضافة إلى الشاشة الرئيسية»</b>');
      }, 2500);
    });
  }
})();
