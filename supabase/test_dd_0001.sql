-- =========================================================
-- اختبار dd_0001 داخل معاملة تُلغى بالكامل في النهاية (لا يبقى أي أثر)
-- يُلصق بعد ملف الـ migration مباشرة؛ الـ RAISE في الآخر يعرض النتائج ويلغي كل شيء
-- =========================================================
do $$
declare
  rid   constant uuid := 'eb399736-4a86-4109-86c5-798720f6d242';
  staff constant text := (select id::text from auth.users where email = 'daily.dose11222@gmail.com');
  probe constant text := (select id::text from auth.users where email = 'zzpentestprobe@gmail.com');
  res text := '';
  n int; j jsonb; code text;
  procedure_ok boolean;
begin
  -- ===== 1) زائر بدون دخول =====
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  select count(*) into n from public.products;      res := res || format(E'\n[زائر] يقرأ المنتجات: %s', n);
  select count(*) into n from public.categories;    res := res || format(' | الأقسام: %s', n);
  begin select count(*) into n from public.orders; res := res || format(E'\n[زائر] يقرأ الطلبات: %s ❌', n);
  exception when insufficient_privilege then res := res || E'\n[زائر] الطلبات: مرفوض ✓'; end;
  begin update public.products set price = 0; res := res || E'\n[زائر] تغيير الأسعار: نجح ❌';
  exception when insufficient_privilege then res := res || E'\n[زائر] تغيير الأسعار: مرفوض ✓'; end;
  j := public.loyalty_join(rid, 'زبون تجريبي', '0999123456'); code := j->>'code';
  res := res || format(E'\n[زائر] إنشاء بطاقة: ✓ رمز=%s أختام=%s/%s هدية=%s', code, j->>'stamps', j->>'needed', j->>'reward');
  begin perform public.loyalty_join(rid, 'شخص آخر', '+963 999 123 456'); res := res || E'\n[زائر] نفس الرقم مرتين: سُمح ❌';
  exception when others then res := res || E'\n[زائر] نفس الرقم مرتين (صيغة مختلفة): مرفوض ✓ — ' || sqlerrm; end;
  j := public.loyalty_card(code);
  res := res || format(E'\n[زائر] قراءة بطاقته بالرمز: ✓ (رقم الجوال ظاهر؟ %s)', case when j ? 'phone' then 'نعم ❌' else 'لا ✓' end);
  begin perform public.loyalty_stamp(code, 1); res := res || E'\n[زائر] إضافة ختم لنفسه: نجح ❌';
  exception when insufficient_privilege then res := res || E'\n[زائر] إضافة ختم لنفسه: مرفوض ✓'; end;
  begin select count(*) into n from public.loyalty_cards; res := res || E'\n[زائر] قراءة كل البطاقات: نجح ❌';
  exception when insufficient_privilege then res := res || E'\n[زائر] قراءة كل البطاقات (الأرقام): مرفوض ✓'; end;
  reset role;

  -- ===== 2) حساب مسجّل ليس موظفاً =====
  perform set_config('request.jwt.claims', json_build_object('sub', probe, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.orders;  res := res || format(E'\n[غير موظف] يرى الطلبات: %s صف %s', n, case when n = 0 then '✓' else '❌' end);
  update public.products set price = price;   get diagnostics n = row_count; res := res || format(E'\n[غير موظف] يعدّل المنتجات: %s صف %s', n, case when n = 0 then '✓' else '❌' end);
  update public.restaurant_settings set wifi_tracking_enabled = wifi_tracking_enabled; get diagnostics n = row_count;
  res := res || format(E'\n[غير موظف] يعدّل الإعدادات: %s صف %s', n, case when n = 0 then '✓' else '❌' end);
  select count(*) into n from public.loyalty_cards; res := res || format(E'\n[غير موظف] يرى البطاقات: %s %s', n, case when n = 0 then '✓' else '❌' end);
  begin perform public.loyalty_stamp(code, 1); res := res || E'\n[غير موظف] يضيف ختم: نجح ❌';
  exception when insufficient_privilege then res := res || E'\n[غير موظف] يضيف ختم: مرفوض ✓'; end;
  select count(*) into n from public.products; res := res || format(E'\n[غير موظف] يقرأ المنيو: %s ✓', n);
  reset role;

  -- ===== 3) موظف (المدير) =====
  perform set_config('request.jwt.claims', json_build_object('sub', staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.orders;  res := res || format(E'\n[موظف] يرى الطلبات: %s %s', n, case when n > 0 then '✓' else '❌' end);
  update public.products set price = price where restaurant_id = rid; get diagnostics n = row_count;
  res := res || format(E'\n[موظف] يعدّل المنتجات: %s صف %s', n, case when n > 0 then '✓' else '❌' end);
  update public.orders set status = status where restaurant_id = rid; get diagnostics n = row_count;
  res := res || format(E'\n[موظف] يحدّث حالة الطلبات: %s صف %s', n, case when n > 0 then '✓' else '❌' end);
  select count(*) into n from public.staff_members; res := res || E'\n[موظف] يقرأ الموظفين: ✓';
  select count(*) into n from public.tables;        res := res || format(E'\n[موظف] يقرأ الطاولات: %s ✓', n);
  select jsonb_array_length(public.loyalty_find('123456')) into n; res := res || format(E'\n[موظف] يبحث بآخر أرقام الجوال: %s نتيجة %s', n, case when n = 1 then '✓' else '❌' end);
  for i in 1..8 loop j := public.loyalty_stamp(lower(code), 1); end loop;
  res := res || format(E'\n[موظف] 8 أختام: %s/%s ✓', j->>'stamps', j->>'needed');
  j := public.loyalty_redeem(code); res := res || format(E'\n[موظف] استبدال الهدية: أختام=%s هدايا=%s ✓', j->>'stamps', j->>'rewards_redeemed');
  begin perform public.loyalty_redeem(code); res := res || E'\n[موظف] استبدال بدون أختام كافية: سُمح ❌';
  exception when others then res := res || E'\n[موظف] استبدال بدون أختام كافية: مرفوض ✓ — ' || sqlerrm; end;
  j := public.loyalty_stamp(code, 1); j := public.loyalty_unstamp(code); res := res || format(E'\n[موظف] ختم ثم تراجع: %s ✓', j->>'stamps');
  j := public.loyalty_save_settings(8, 'قهوة مجانية', true); res := res || E'\n[مدير] حفظ إعدادات البطاقة: ✓';
  reset role;

  raise exception 'TEST RESULTS (rolled back):%', res;
end $$;
