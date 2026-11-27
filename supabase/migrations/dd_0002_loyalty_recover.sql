-- =========================================================
-- Daily Dose — dd_0002: «عندي بطاقة»
-- الزبون يرجّع بطاقته على أي جهاز بنفس الاسم + رقم الجوال اللي سجّل فيهم.
-- حماية: لازم الاسم والرقم يتطابقوا سوا، وبعد 5 محاولات غلط على نفس الرقم بيتوقف ساعة.
-- لا حذف لأي بيانات زبائن؛ فقط دوال جديدة/محدّثة + جدول عدّاد محاولات بالمخطط الخاص.
-- =========================================================

-- عدّاد المحاولات الغلط (بالمخطط private: غير مكشوف للـ API)
create table if not exists private.dd_recover_fails (
  id            bigint generated always as identity primary key,
  restaurant_id uuid not null,
  phone         text not null,
  at            timestamptz not null default now()
);
create index if not exists dd_recover_fails_phone_at on private.dd_recover_fails (restaurant_id, phone, at);
revoke all on table private.dd_recover_fails from public, anon, authenticated;

-- توحيد كتابة الاسم: بدون تشكيل/تطويل، أ إ آ ← ا، ة ← ه، ى ← ي، مسافات موحّدة، أحرف صغيرة
create or replace function private.dd_name_key(p text)
returns text language sql immutable set search_path = '' as $$
  select lower(btrim(regexp_replace(
           translate(regexp_replace(coalesce(p, ''), '[ًٌٍَُِّْـ]', '', 'g'), 'أإآٱةى', 'ااااهي'),
         '\s+', ' ', 'g')))
$$;
revoke all on function private.dd_name_key(text) from public;

-- إرجاع البطاقة بالاسم + الرقم. ترجع JSON فيه البطاقة، أو {"error": "..."}
-- (ما منستعمل raise للخطأ حتى ما يلغي تسجيل المحاولة الغلط)
create or replace function public.loyalty_recover(p_restaurant uuid, p_name text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.loyalty_settings;
  c public.loyalty_cards;
  v_phone text := private.dd_phone(p_phone);
  v_msg constant text := 'الاسم أو الرقم ما بيطابقوا بطاقة مسجّلة. اكتبهم متل أول مرة سجّلت، أو اطلب من الكاشير.';
begin
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  if not found or not s.active then return jsonb_build_object('error', 'بطاقة الولاء غير متاحة حالياً.'); end if;
  if char_length(btrim(coalesce(p_name, ''))) < 2 then return jsonb_build_object('error', 'اكتب اسمك متل ما سجّلته.'); end if;
  if v_phone !~ '^[0-9]{7,15}$' then return jsonb_build_object('error', 'رقم الجوال غير صحيح.'); end if;

  -- تنظيف المحاولات القديمة
  delete from private.dd_recover_fails where at < now() - interval '1 day';

  if (select count(*) from private.dd_recover_fails
      where restaurant_id = p_restaurant and phone = v_phone and at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('error', 'محاولات كتيرة على هالرقم. جرّب بعد ساعة، أو اطلب من الكاشير يرجّعلك بطاقتك.');
  end if;
  if (select count(*) from private.dd_recover_fails
      where restaurant_id = p_restaurant and at > now() - interval '1 minute') >= 30 then
    return jsonb_build_object('error', 'ضغط كبير حالياً، جرّب بعد دقيقة.');
  end if;

  select * into c from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone;
  if not found or private.dd_name_key(c.name) <> private.dd_name_key(p_name) then
    insert into private.dd_recover_fails (restaurant_id, phone) values (p_restaurant, v_phone);
    return jsonb_build_object('error', v_msg);  -- نفس الرسالة بالحالتين: ما منكشف إذا الرقم مسجّل
  end if;

  delete from private.dd_recover_fails where restaurant_id = p_restaurant and phone = v_phone;
  return private.dd_card_json(c, s);
end $$;

revoke all on function public.loyalty_recover(uuid, text, text) from public, anon, authenticated;
grant execute on function public.loyalty_recover(uuid, text, text) to anon, authenticated;

-- نفس دالة التسجيل، بس رسالة الرقم المكرر بتدلّ على «عندي بطاقة»
create or replace function public.loyalty_join(p_restaurant uuid, p_name text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.loyalty_settings;
  c public.loyalty_cards;
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := private.dd_phone(p_phone);
  v_dup constant text := 'هذا الرقم عنده بطاقة من قبل. اكبس «عندي بطاقة» واكتب نفس اسمك ورقمك.';
begin
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  if not found or not s.active then raise exception 'بطاقة الولاء غير متاحة حالياً.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'اكتب اسمك (حرفين على الأقل).'; end if;
  if v_phone !~ '^[0-9]{7,15}$' then raise exception 'رقم الجوال غير صحيح. اكتبه مع رمز الدولة أو يبدأ بـ 09.'; end if;
  if (select count(*) from public.loyalty_cards where restaurant_id = p_restaurant and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'ضغط كبير حالياً، جرّب بعد دقيقة.';
  end if;
  if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
    raise exception '%', v_dup;
  end if;
  for i in 1..5 loop
    begin
      insert into public.loyalty_cards (restaurant_id, code, name, phone)
      values (p_restaurant, private.dd_loyalty_code(), v_name, v_phone)
      returning * into c;
      exit;
    exception when unique_violation then
      if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
        raise exception '%', v_dup;
      end if;   -- تصادم نادر في الرمز: نجرّب رمزاً آخر
    end;
  end loop;
  if c.id is null then raise exception 'تعذّر إنشاء البطاقة، حاول مرة أخرى.'; end if;
  insert into public.loyalty_events (card_id, kind, amount) values (c.id, 'join', 0);
  return private.dd_card_json(c, s);
end $$;
