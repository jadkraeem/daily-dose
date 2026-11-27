-- =========================================================
-- Daily Dose — dd_0003: تحكم كامل ببطاقة الولاء
--  • إعدادات جديدة: ختم ترحيبي، حد أختام باليوم، تسجيل ذاتي مفتوح/مسكّر، رسالة على البطاقة
--  • الكاشير: إنشاء بطاقة لزبون
--  • المدير فقط: تعديل بطاقة (اسم/رقم/أختام) وحذفها
-- لا حذف لأي عمود أو جدول؛ أعمدة جديدة بقيم افتراضية + دوال جديدة/محدّثة.
-- =========================================================

alter table public.loyalty_settings
  add column if not exists welcome_stamps int     not null default 0  check (welcome_stamps between 0 and 5),
  add column if not exists daily_limit    int     not null default 0  check (daily_limit between 0 and 20),
  add column if not exists allow_signup   boolean not null default true,
  add column if not exists card_note      text    not null default '' check (char_length(card_note) <= 200);

-- بطاقة الزبون صار فيها رسالة المقهى
create or replace function private.dd_card_json(c public.loyalty_cards, s public.loyalty_settings)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'code', c.code, 'name', c.name, 'stamps', c.stamps, 'needed', s.stamps_needed,
    'reward', s.reward, 'rewards_redeemed', c.rewards_redeemed, 'active', s.active,
    'note', s.card_note,
    'cafe', (select r.name from public.restaurants r where r.id = c.restaurant_id))
$$;
revoke all on function private.dd_card_json(public.loyalty_cards, public.loyalty_settings) from public;

-- إنشاء بطاقة (مشترك بين تسجيل الزبون والكاشير): رمز فريد + ختم ترحيبي
create or replace function private.dd_create_card(p_restaurant uuid, p_name text, p_phone text, p_staff uuid)
returns public.loyalty_cards language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.loyalty_settings;
  c public.loyalty_cards;
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := private.dd_phone(p_phone);
  v_dup constant text := 'هذا الرقم عنده بطاقة من قبل. اكبس «عندي بطاقة» واكتب نفس اسمك ورقمك.';
begin
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  if not found or not s.active then raise exception 'بطاقة الولاء غير متاحة حالياً.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'اكتب الاسم (حرفين على الأقل).'; end if;
  if v_phone !~ '^[0-9]{7,15}$' then raise exception 'رقم الجوال غير صحيح. اكتبه مع رمز الدولة أو يبدأ بـ 09.'; end if;
  if (select count(*) from public.loyalty_cards where restaurant_id = p_restaurant and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'ضغط كبير حالياً، جرّب بعد دقيقة.';
  end if;
  if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
    raise exception '%', v_dup;
  end if;
  for i in 1..5 loop
    begin
      insert into public.loyalty_cards (restaurant_id, code, name, phone, stamps, last_stamp_at)
      values (p_restaurant, private.dd_loyalty_code(), v_name, v_phone, s.welcome_stamps,
              case when s.welcome_stamps > 0 then now() end)
      returning * into c;
      exit;
    exception when unique_violation then
      if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
        raise exception '%', v_dup;
      end if;   -- تصادم نادر في الرمز: نجرّب رمزاً آخر
    end;
  end loop;
  if c.id is null then raise exception 'تعذّر إنشاء البطاقة، حاول مرة أخرى.'; end if;
  insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'join', 0, p_staff);
  if s.welcome_stamps > 0 then
    insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'stamp', s.welcome_stamps, null);
  end if;
  return c;
end $$;
revoke all on function private.dd_create_card(uuid, text, text, uuid) from public;

-- تسجيل الزبون بنفسه (بيحترم «التسجيل الذاتي»)
create or replace function public.loyalty_join(p_restaurant uuid, p_name text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.loyalty_settings; c public.loyalty_cards;
begin
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  if found and s.active and not s.allow_signup then
    raise exception 'التسجيل من الجوال متوقف حالياً. اطلب من الكاشير يعملك بطاقة.';
  end if;
  c := private.dd_create_card(p_restaurant, p_name, p_phone, null);
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  return private.dd_card_json(c, s);
end $$;

-- الكاشير بيعمل بطاقة لزبون (حتى لو التسجيل الذاتي مسكّر)
create or replace function public.loyalty_staff_create(p_name text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rid uuid := private.dd_staff_restaurant(); c public.loyalty_cards; s public.loyalty_settings;
begin
  if v_rid is null then raise exception 'هذه العملية للموظفين فقط.' using errcode = '42501'; end if;
  c := private.dd_create_card(v_rid, p_name, p_phone, auth.uid());
  select * into s from public.loyalty_settings where restaurant_id = v_rid;
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone, 'last_stamp_at', c.last_stamp_at);
end $$;

-- الختم: صار بيحترم «أقصى أختام باليوم» (بتوقيت دمشق)
create or replace function public.loyalty_stamp(p_code text, p_count int default 1)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards; s public.loyalty_settings; v_today int;
begin
  if p_count is null or p_count < 1 or p_count > 5 then raise exception 'عدد الأختام بين 1 و 5.'; end if;
  c := private.dd_staff_card(p_code);
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  if not s.active then raise exception 'بطاقة الولاء متوقفة من الإعدادات.'; end if;
  if s.daily_limit > 0 then
    select coalesce(sum(case kind when 'stamp' then amount when 'unstamp' then -amount else 0 end), 0) into v_today
      from public.loyalty_events
     where card_id = c.id and staff_id is not null
       and created_at >= (date_trunc('day', now() at time zone 'Asia/Damascus')) at time zone 'Asia/Damascus';
    if v_today + p_count > s.daily_limit then
      raise exception 'هالزبون أخد % ختم اليوم، والحد % باليوم.', greatest(v_today, 0), s.daily_limit;
    end if;
  end if;
  update public.loyalty_cards set stamps = least(stamps + p_count, 100), last_stamp_at = now()
   where id = c.id returning * into c;
  insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'stamp', p_count, auth.uid());
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone, 'last_stamp_at', c.last_stamp_at);
end $$;

-- كل الإعدادات (المدير فقط)
create or replace function public.loyalty_update_settings(
  p_needed int, p_reward text, p_active boolean,
  p_welcome int, p_daily_limit int, p_allow_signup boolean, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.loyalty_settings;
begin
  if not private.dd_is_admin() then raise exception 'إعدادات البطاقة للمدير فقط.' using errcode = '42501'; end if;
  if p_needed is null or p_needed < 2 or p_needed > 30 then raise exception 'عدد الأختام بين 2 و 30.'; end if;
  if char_length(btrim(coalesce(p_reward, ''))) < 1 or char_length(btrim(p_reward)) > 60 then raise exception 'اكتب الهدية (حتى 60 حرف).'; end if;
  if p_welcome is null or p_welcome < 0 or p_welcome > 5 then raise exception 'الختم الترحيبي بين 0 و 5.'; end if;
  if p_welcome >= p_needed then raise exception 'الختم الترحيبي لازم يكون أقل من عدد أختام الهدية.'; end if;
  if p_daily_limit is null or p_daily_limit < 0 or p_daily_limit > 20 then raise exception 'حد الأختام باليوم بين 0 و 20 (0 = بلا حد).'; end if;
  if char_length(coalesce(p_note, '')) > 200 then raise exception 'رسالة البطاقة حتى 200 حرف.'; end if;
  update public.loyalty_settings
     set stamps_needed = p_needed, reward = btrim(p_reward), active = coalesce(p_active, true),
         welcome_stamps = p_welcome, daily_limit = p_daily_limit,
         allow_signup = coalesce(p_allow_signup, true), card_note = btrim(coalesce(p_note, '')),
         updated_at = now()
   where restaurant_id = private.dd_staff_restaurant()
  returning * into s;
  return to_jsonb(s);
end $$;

-- تعديل بطاقة (المدير فقط). تغيير الأختام بيتسجّل بالسجل كختم/تراجع
create or replace function public.loyalty_edit_card(p_code text, p_name text, p_phone text, p_stamps int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  c public.loyalty_cards; s public.loyalty_settings;
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := private.dd_phone(p_phone);
  v_diff int;
begin
  if not private.dd_is_admin() then raise exception 'تعديل البطاقات للمدير فقط.' using errcode = '42501'; end if;
  c := private.dd_staff_card(p_code);
  if char_length(v_name) < 1 or char_length(v_name) > 60 then raise exception 'اكتب الاسم (حتى 60 حرف).'; end if;
  if v_phone !~ '^[0-9]{7,15}$' then raise exception 'رقم الجوال غير صحيح.'; end if;
  if p_stamps is null or p_stamps < 0 or p_stamps > 100 then raise exception 'الأختام بين 0 و 100.'; end if;
  v_diff := p_stamps - c.stamps;
  begin
    update public.loyalty_cards
       set name = v_name, phone = v_phone, stamps = p_stamps,
           last_stamp_at = case when v_diff > 0 then now() else last_stamp_at end
     where id = c.id returning * into c;
  exception when unique_violation then
    raise exception 'هالرقم مسجّل لبطاقة تانية.';
  end;
  if v_diff > 0 then insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'stamp', v_diff, auth.uid());
  elsif v_diff < 0 then insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'unstamp', -v_diff, auth.uid());
  end if;
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone, 'last_stamp_at', c.last_stamp_at);
end $$;

-- حذف بطاقة (المدير فقط) — نهائي، مع سجلها
create or replace function public.loyalty_delete_card(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards;
begin
  if not private.dd_is_admin() then raise exception 'حذف البطاقات للمدير فقط.' using errcode = '42501'; end if;
  c := private.dd_staff_card(p_code);
  delete from public.loyalty_cards where id = c.id;
  return jsonb_build_object('deleted', c.code, 'name', c.name);
end $$;

-- ---------- الصلاحيات ----------
revoke all on function public.loyalty_staff_create(text, text),
  public.loyalty_update_settings(int, text, boolean, int, int, boolean, text),
  public.loyalty_edit_card(text, text, text, int), public.loyalty_delete_card(text)
  from public, anon, authenticated;
grant execute on function public.loyalty_staff_create(text, text),
  public.loyalty_update_settings(int, text, boolean, int, int, boolean, text),
  public.loyalty_edit_card(text, text, text, int), public.loyalty_delete_card(text)
  to authenticated;
-- (loyalty_join و loyalty_stamp محتفظين بصلاحياتهم القديمة لأنو create or replace ما بيغيّرها)
