-- اختبار dd_0003 — كلشي بينلغى بالآخر (raise)، ما بيبقى أي أثر بالقاعدة
do $$
declare
  rid uuid := 'eb399736-4a86-4109-86c5-798720f6d242';
  admin_id text := '15230070-a1fe-4be9-8d56-f18664b21236';
  c jsonb; c2 jsonb; r jsonb; res text := ''; ok int := 0; bad int := 0;
begin
  -- نتصرّف كالمدير
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true);

  -- ١) حفظ كل الإعدادات
  r := public.loyalty_update_settings(8, 'قهوة مجانية', true, 1, 2, true, 'الهدية لا تشمل الحلويات');
  if (r->>'welcome_stamps')::int = 1 and (r->>'daily_limit')::int = 2 and r->>'card_note' = 'الهدية لا تشمل الحلويات' then ok := ok + 1; res := res || ' ✓settings'; else bad := bad + 1; res := res || ' ✗settings:' || r::text; end if;

  -- ٢) تسجيل زبون ← ختم ترحيبي + رسالة البطاقة
  c := public.loyalty_join(rid, 'تجربة أولى', '0999111001');
  if (c->>'stamps')::int = 1 and c->>'note' = 'الهدية لا تشمل الحلويات' then ok := ok + 1; res := res || ' ✓welcome+note'; else bad := bad + 1; res := res || ' ✗welcome:' || c::text; end if;

  -- ٣) حد الأختام باليوم = 2 (الترحيبي ما بينحسب)
  perform public.loyalty_stamp(c->>'code', 1);
  r := public.loyalty_stamp(c->>'code', 1);
  if (r->>'stamps')::int = 3 then ok := ok + 1; res := res || ' ✓2stamps'; else bad := bad + 1; res := res || ' ✗2stamps:' || r::text; end if;
  begin
    perform public.loyalty_stamp(c->>'code', 1);
    bad := bad + 1; res := res || ' ✗limitNotApplied';
  exception when others then
    if sqlerrm like '%الحد 2%' then ok := ok + 1; res := res || ' ✓dailyLimit'; else bad := bad + 1; res := res || ' ✗limit:' || sqlerrm; end if;
  end;

  -- ٤) تسكير التسجيل الذاتي ← الزبون ما بيقدر، الكاشير بيقدر
  perform public.loyalty_update_settings(8, 'قهوة مجانية', true, 0, 0, false, '');
  begin
    perform public.loyalty_join(rid, 'تجربة تانية', '0999111002');
    bad := bad + 1; res := res || ' ✗signupStillOpen';
  exception when others then
    if sqlerrm like '%متوقف%' then ok := ok + 1; res := res || ' ✓signupClosed'; else bad := bad + 1; res := res || ' ✗signup:' || sqlerrm; end if;
  end;
  c2 := public.loyalty_staff_create('تجربة تانية', '0999111002');
  if c2->>'phone' = '963999111002' and (c2->>'stamps')::int = 0 then ok := ok + 1; res := res || ' ✓staffCreate'; else bad := bad + 1; res := res || ' ✗staffCreate:' || c2::text; end if;

  -- ٥) تعديل بطاقة
  r := public.loyalty_edit_card(c->>'code', 'اسم معدّل', '0999111003', 7);
  if r->>'name' = 'اسم معدّل' and r->>'phone' = '963999111003' and (r->>'stamps')::int = 7 then ok := ok + 1; res := res || ' ✓edit'; else bad := bad + 1; res := res || ' ✗edit:' || r::text; end if;
  begin
    perform public.loyalty_edit_card(c->>'code', 'اسم معدّل', '0999111002', 7);  -- رقم البطاقة التانية
    bad := bad + 1; res := res || ' ✗dupPhoneAllowed';
  exception when others then
    if sqlerrm like '%بطاقة تانية%' then ok := ok + 1; res := res || ' ✓editDupPhone'; else bad := bad + 1; res := res || ' ✗editDup:' || sqlerrm; end if;
  end;

  -- ٦) حذف بطاقة (ومعها سجلها)
  r := public.loyalty_delete_card(c->>'code');
  if not exists (select 1 from public.loyalty_cards where code = c->>'code') then ok := ok + 1; res := res || ' ✓delete'; else bad := bad + 1; res := res || ' ✗delete'; end if;

  -- ٧) مستخدم مو موظف ← ممنوع
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin
    perform public.loyalty_delete_card(c2->>'code');
    bad := bad + 1; res := res || ' ✗strangerDeleted';
  exception when others then ok := ok + 1; res := res || ' ✓strangerBlocked'; end;
  begin
    perform public.loyalty_update_settings(8, 'x', true, 0, 0, true, '');
    bad := bad + 1; res := res || ' ✗strangerSettings';
  exception when others then ok := ok + 1; res := res || ' ✓strangerNoSettings'; end;

  -- ٨) الزائر (anon) ما عنده صلاحية على دوال الإدارة
  if not has_function_privilege('anon', 'public.loyalty_delete_card(text)', 'execute')
     and not has_function_privilege('anon', 'public.loyalty_edit_card(text,text,text,int)', 'execute')
     and not has_function_privilege('anon', 'public.loyalty_staff_create(text,text)', 'execute')
     and not has_function_privilege('anon', 'public.loyalty_update_settings(int,text,boolean,int,int,boolean,text)', 'execute')
  then ok := ok + 1; res := res || ' ✓anonBlocked'; else bad := bad + 1; res := res || ' ✗anonHasAccess'; end if;

  raise exception 'TEST RESULTS (rolled back): % passed, % failed →%', ok, bad, res;
end $$;
