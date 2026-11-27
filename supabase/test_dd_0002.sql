-- اختبار dd_0002 داخل معاملة تنلغى بالكامل في الآخر (raise) — ما بيبقى أي أثر بالقاعدة
do $$
declare
  rid uuid := 'eb399736-4a86-4109-86c5-798720f6d242';
  c jsonb; r jsonb; res text := ''; ok int := 0; bad int := 0;
begin
  c := public.loyalty_join(rid, 'سارة أحمد', '0999000111');

  -- ١) نفس الاسم والرقم ← نفس البطاقة
  r := public.loyalty_recover(rid, 'سارة أحمد', '0999000111');
  if r->>'code' = c->>'code' then ok := ok + 1; res := res || ' ✓same'; else bad := bad + 1; res := res || ' ✗same:' || r::text; end if;

  -- ٢) كتابة مختلفة شوي (ساره احمد، مسافات، رقم دولي) ← تقبل
  r := public.loyalty_recover(rid, '  ساره   احمد ', '+963 999 000 111');
  if r->>'code' = c->>'code' then ok := ok + 1; res := res || ' ✓variant'; else bad := bad + 1; res := res || ' ✗variant:' || r::text; end if;

  -- ٣) ما في رقم الجوال بالرد
  if r ? 'phone' then bad := bad + 1; res := res || ' ✗phoneLeak'; else ok := ok + 1; res := res || ' ✓noPhone'; end if;

  -- ٤) اسم غلط ← رفض
  r := public.loyalty_recover(rid, 'محمد', '0999000111');
  if r ? 'error' and not r ? 'code' then ok := ok + 1; res := res || ' ✓wrongName'; else bad := bad + 1; res := res || ' ✗wrongName'; end if;

  -- ٥) رقم غير مسجّل ← نفس الرسالة بالضبط
  if (public.loyalty_recover(rid, 'محمد', '0999000222'))->>'error' = r->>'error' then ok := ok + 1; res := res || ' ✓sameMsg'; else bad := bad + 1; res := res || ' ✗sameMsg'; end if;

  -- ٦) بعد 5 غلطات ← حتى الاسم الصح بيتوقف
  perform public.loyalty_recover(rid, 'x1', '0999000111');
  perform public.loyalty_recover(rid, 'x2', '0999000111');
  perform public.loyalty_recover(rid, 'x3', '0999000111');
  perform public.loyalty_recover(rid, 'x4', '0999000111');
  r := public.loyalty_recover(rid, 'سارة أحمد', '0999000111');
  if r ? 'error' and r->>'error' like 'محاولات كتيرة%' then ok := ok + 1; res := res || ' ✓locked'; else bad := bad + 1; res := res || ' ✗locked:' || r::text; end if;

  -- ٧) التسجيل المكرر ← رسالة «عندي بطاقة»
  begin
    perform public.loyalty_join(rid, 'حدا تاني', '0999000111');
    bad := bad + 1; res := res || ' ✗dupAllowed';
  exception when others then
    if sqlerrm like '%عندي بطاقة%' then ok := ok + 1; res := res || ' ✓dupMsg'; else bad := bad + 1; res := res || ' ✗dupMsg:' || sqlerrm; end if;
  end;

  -- ٨) الصلاحيات: anon بيقدر ينفّذ الدالة، وما بيقدر يقرأ جدول المحاولات
  if has_function_privilege('anon', 'public.loyalty_recover(uuid,text,text)', 'execute') then ok := ok + 1; res := res || ' ✓anonExec'; else bad := bad + 1; res := res || ' ✗anonExec'; end if;
  if not has_table_privilege('anon', 'private.dd_recover_fails', 'select') and not has_table_privilege('authenticated', 'private.dd_recover_fails', 'select') then ok := ok + 1; res := res || ' ✓failsHidden'; else bad := bad + 1; res := res || ' ✗failsVisible'; end if;

  raise exception 'TEST RESULTS (rolled back): % passed, % failed →%', ok, bad, res;
end $$;
