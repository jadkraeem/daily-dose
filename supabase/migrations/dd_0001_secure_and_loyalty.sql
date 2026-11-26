-- =========================================================
-- Daily Dose — 0001: تشديد الحماية + بطاقة الولاء
-- =========================================================
-- الجزء أ (الحماية):
--   قبل: أي حساب مسجّل دخول (حتى لو ليس موظفاً) عنده صلاحية كاملة على كل الجداول،
--        والتسجيل العام مفتوح. الزوار بدون دخول كانوا يقرؤون المنيو فقط (صلاحيات الجداول تحميهم).
--   بعد: الزائر يقرأ المنيو فقط (المنتجات، الأقسام، العروض، الفعاليات) — كما هو.
--        الكتابة وقراءة الطلبات والإعدادات والموظفين: للموظفين المسجّلين في profiles فقط، ولمطعمهم فقط.
--        إرسال الطلب يبقى عبر place_order (دالة آمنة، لا تتأثر).
-- الجزء ب (بطاقة الولاء):
--   الزبون ينشئ بطاقته باسمه ورقمه، ويرى أختامه برمز سري. إضافة الأختام والاستبدال للموظفين فقط.
--   كل التعديلات عبر دوال (RPC) بفحوص صارمة؛ لا كتابة مباشرة على جداول الولاء.
-- =========================================================

-- ---------- أدوات خاصة (خارج الـ API) ----------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- مطعم الموظف الحالي (أو null إن لم يكن موظفاً)
create or replace function private.dd_staff_restaurant()
returns uuid language sql stable security definer set search_path = '' as $$
  select p.restaurant_id from public.profiles p where p.id = auth.uid()
$$;

create or replace function private.dd_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.role = 'admin' from public.profiles p where p.id = auth.uid()), false)
$$;

revoke all on function private.dd_staff_restaurant(), private.dd_is_admin() from public;
grant execute on function private.dd_staff_restaurant(), private.dd_is_admin() to authenticated;

-- =========================================================
-- الجزء أ: استبدال القواعد المفتوحة
-- =========================================================
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('categories','products','promotions','events','orders','order_items',
                        'restaurant_settings','staff_members','tables','sites_config','site_records','ai_messages')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- محتوى المنيو: الكل يقرأ، وموظفو المطعم يعدّلون
create policy menu_read   on public.categories for select to anon, authenticated using (true);
create policy staff_write on public.categories for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));

create policy menu_read   on public.products for select to anon, authenticated using (true);
create policy staff_write on public.products for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));

create policy menu_read   on public.promotions for select to anon, authenticated using (true);
create policy staff_write on public.promotions for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));

create policy menu_read   on public.events for select to anon, authenticated using (true);
create policy staff_write on public.events for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));

-- الطلبات والإعدادات والموظفين: موظفو المطعم فقط
create policy staff_all on public.orders for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));
create policy staff_all on public.restaurant_settings for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));
create policy staff_all on public.staff_members for all to authenticated
  using (restaurant_id = (select private.dd_staff_restaurant())) with check (restaurant_id = (select private.dd_staff_restaurant()));

-- جداول بلا restaurant_id (مطعم واحد): أي موظف
create policy staff_read on public.order_items for select to authenticated using ((select private.dd_staff_restaurant()) is not null);
create policy staff_all  on public.tables       for all to authenticated using ((select private.dd_staff_restaurant()) is not null) with check ((select private.dd_staff_restaurant()) is not null);
create policy staff_all  on public.sites_config for all to authenticated using ((select private.dd_staff_restaurant()) is not null) with check ((select private.dd_staff_restaurant()) is not null);
create policy staff_all  on public.site_records for all to authenticated using ((select private.dd_staff_restaurant()) is not null) with check ((select private.dd_staff_restaurant()) is not null);
create policy staff_all  on public.ai_messages  for all to authenticated using ((select private.dd_staff_restaurant()) is not null) with check ((select private.dd_staff_restaurant()) is not null);

-- صلاحيات لا يحتاجها أحد عبر الـ API (حماية إضافية)
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- =========================================================
-- الجزء ب: بطاقة الولاء
-- =========================================================
create table public.loyalty_settings (
  restaurant_id  uuid primary key references public.restaurants (id) on delete cascade,
  stamps_needed  int  not null default 8 check (stamps_needed between 2 and 30),
  reward         text not null default 'قهوة مجانية' check (char_length(reward) between 1 and 60),
  active         boolean not null default true,
  updated_at     timestamptz not null default now()
);
insert into public.loyalty_settings (restaurant_id) select id from public.restaurants on conflict do nothing;

create table public.loyalty_cards (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null references public.restaurants (id) on delete cascade,
  code             text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  name             text not null check (char_length(name) between 1 and 60),
  phone            text not null check (phone ~ '^[0-9]{7,15}$'),
  stamps           int  not null default 0 check (stamps between 0 and 100),
  rewards_redeemed int  not null default 0 check (rewards_redeemed >= 0),
  last_stamp_at    timestamptz,
  created_at       timestamptz not null default now(),
  unique (restaurant_id, phone)
);
create index loyalty_cards_created_idx on public.loyalty_cards (restaurant_id, created_at desc);

create table public.loyalty_events (
  id         bigint generated always as identity primary key,
  card_id    uuid not null references public.loyalty_cards (id) on delete cascade,
  kind       text not null check (kind in ('join', 'stamp', 'unstamp', 'redeem')),
  amount     int  not null default 1,
  staff_id   uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
create index loyalty_events_card_idx on public.loyalty_events (card_id, created_at desc);
create index loyalty_events_staff_idx on public.loyalty_events (staff_id);

alter table public.loyalty_settings enable row level security;
alter table public.loyalty_cards    enable row level security;
alter table public.loyalty_events   enable row level security;

-- القراءة المباشرة للموظفين فقط؛ الزبون يقرأ بطاقته عبر loyalty_card (بلا رقم الجوال)
revoke all on public.loyalty_settings, public.loyalty_cards, public.loyalty_events from anon, authenticated;
grant select on public.loyalty_settings, public.loyalty_cards, public.loyalty_events to authenticated;
create policy staff_read on public.loyalty_settings for select to authenticated using (restaurant_id = (select private.dd_staff_restaurant()));
create policy staff_read on public.loyalty_cards    for select to authenticated using (restaurant_id = (select private.dd_staff_restaurant()));
create policy staff_read on public.loyalty_events   for select to authenticated
  using (exists (select 1 from public.loyalty_cards c where c.id = card_id and c.restaurant_id = (select private.dd_staff_restaurant())));

-- ---------- أدوات داخلية ----------
-- رمز سري من 10 أحرف بلا أحرف ملتبسة (بدون I و O و 0 و 1)
create or replace function private.dd_loyalty_code()
returns text language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(10);
  out text := '';
begin
  for i in 0..9 loop
    out := out || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return out;
end $$;

-- توحيد رقم الجوال: أرقام فقط، 00 في البداية تُحذف، و 09xxxxxxxx (سوريا) تصبح 9639xxxxxxxx
create or replace function private.dd_phone(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when d ~ '^00' then substr(d, 3)
    when d ~ '^09[0-9]{8}$' then '963' || substr(d, 2)
    else d end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) s
$$;

create or replace function private.dd_card_json(c public.loyalty_cards, s public.loyalty_settings)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'code', c.code, 'name', c.name, 'stamps', c.stamps, 'needed', s.stamps_needed,
    'reward', s.reward, 'rewards_redeemed', c.rewards_redeemed, 'active', s.active,
    'cafe', (select r.name from public.restaurants r where r.id = c.restaurant_id))
$$;

revoke all on function private.dd_loyalty_code(), private.dd_phone(text),
  private.dd_card_json(public.loyalty_cards, public.loyalty_settings) from public;

-- ---------- للزبون ----------
create or replace function public.loyalty_join(p_restaurant uuid, p_name text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.loyalty_settings;
  c public.loyalty_cards;
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := private.dd_phone(p_phone);
begin
  select * into s from public.loyalty_settings where restaurant_id = p_restaurant;
  if not found or not s.active then raise exception 'بطاقة الولاء غير متاحة حالياً.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'اكتب اسمك (حرفين على الأقل).'; end if;
  if v_phone !~ '^[0-9]{7,15}$' then raise exception 'رقم الجوال غير صحيح. اكتبه مع رمز الدولة أو يبدأ بـ 09.'; end if;
  if (select count(*) from public.loyalty_cards where restaurant_id = p_restaurant and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'ضغط كبير حالياً، جرّب بعد دقيقة.';
  end if;
  if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
    raise exception 'هذا الرقم عنده بطاقة من قبل. اطلب من الكاشير يرجّعلك بطاقتك.';
  end if;
  for i in 1..5 loop
    begin
      insert into public.loyalty_cards (restaurant_id, code, name, phone)
      values (p_restaurant, private.dd_loyalty_code(), v_name, v_phone)
      returning * into c;
      exit;
    exception when unique_violation then
      if exists (select 1 from public.loyalty_cards where restaurant_id = p_restaurant and phone = v_phone) then
        raise exception 'هذا الرقم عنده بطاقة من قبل. اطلب من الكاشير يرجّعلك بطاقتك.';
      end if;   -- تصادم نادر في الرمز: نجرّب رمزاً آخر
    end;
  end loop;
  if c.id is null then raise exception 'تعذّر إنشاء البطاقة، حاول مرة أخرى.'; end if;
  insert into public.loyalty_events (card_id, kind, amount) values (c.id, 'join', 0);
  return private.dd_card_json(c, s);
end $$;

-- عرض البطاقة بالرمز السري (بلا رقم الجوال)
create or replace function public.loyalty_card(p_code text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.loyalty_cards; s public.loyalty_settings;
begin
  if coalesce(p_code, '') !~ '^[A-HJ-NP-Z2-9]{10}$' then return null; end if;
  select * into c from public.loyalty_cards where code = p_code;
  if not found then return null; end if;
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  return private.dd_card_json(c, s);
end $$;

-- ---------- للموظفين ----------
create or replace function private.dd_staff_card(p_code text)
returns public.loyalty_cards language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards; v_rid uuid := private.dd_staff_restaurant();
begin
  if v_rid is null then raise exception 'هذه العملية للموظفين فقط.' using errcode = '42501'; end if;
  select * into c from public.loyalty_cards
   where code = upper(btrim(coalesce(p_code, ''))) and restaurant_id = v_rid for update;
  if not found then raise exception 'البطاقة غير موجودة.'; end if;
  return c;
end $$;
revoke all on function private.dd_staff_card(text) from public;

create or replace function public.loyalty_find(p_query text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rid uuid := private.dd_staff_restaurant();
  q text := upper(btrim(coalesce(p_query, '')));
  d text;
begin
  if v_rid is null then raise exception 'هذه العملية للموظفين فقط.' using errcode = '42501'; end if;
  if q ~ '^[A-HJ-NP-Z2-9]{10}$' then
    return coalesce((select jsonb_agg(private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone, 'last_stamp_at', c.last_stamp_at))
      from public.loyalty_cards c join public.loyalty_settings s on s.restaurant_id = c.restaurant_id
      where c.restaurant_id = v_rid and c.code = q), '[]'::jsonb);
  end if;
  d := private.dd_phone(q);
  if char_length(d) < 4 then raise exception 'اكتب رمز البطاقة أو 4 أرقام على الأقل من رقم الجوال.'; end if;
  return coalesce((select jsonb_agg(x) from (
      select private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone, 'last_stamp_at', c.last_stamp_at) as x
      from public.loyalty_cards c join public.loyalty_settings s on s.restaurant_id = c.restaurant_id
      where c.restaurant_id = v_rid and (c.phone = d or c.phone like '%' || d)
      order by c.last_stamp_at desc nulls last limit 10) t), '[]'::jsonb);
end $$;

create or replace function public.loyalty_stamp(p_code text, p_count int default 1)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards; s public.loyalty_settings;
begin
  if p_count is null or p_count < 1 or p_count > 5 then raise exception 'عدد الأختام بين 1 و 5.'; end if;
  c := private.dd_staff_card(p_code);
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  if not s.active then raise exception 'بطاقة الولاء متوقفة من الإعدادات.'; end if;
  update public.loyalty_cards set stamps = least(stamps + p_count, 100), last_stamp_at = now()
   where id = c.id returning * into c;
  insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'stamp', p_count, auth.uid());
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone);
end $$;

create or replace function public.loyalty_unstamp(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards; s public.loyalty_settings;
begin
  c := private.dd_staff_card(p_code);
  if c.stamps < 1 then raise exception 'لا يوجد ختم للتراجع عنه.'; end if;
  update public.loyalty_cards set stamps = stamps - 1 where id = c.id returning * into c;
  insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'unstamp', 1, auth.uid());
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone);
end $$;

create or replace function public.loyalty_redeem(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.loyalty_cards; s public.loyalty_settings;
begin
  c := private.dd_staff_card(p_code);
  select * into s from public.loyalty_settings where restaurant_id = c.restaurant_id;
  if c.stamps < s.stamps_needed then
    raise exception 'باقي % أختام قبل الهدية.', s.stamps_needed - c.stamps;
  end if;
  update public.loyalty_cards set stamps = stamps - s.stamps_needed, rewards_redeemed = rewards_redeemed + 1
   where id = c.id returning * into c;
  insert into public.loyalty_events (card_id, kind, amount, staff_id) values (c.id, 'redeem', s.stamps_needed, auth.uid());
  return private.dd_card_json(c, s) || jsonb_build_object('phone', c.phone);
end $$;

-- إعدادات البطاقة: للمدير فقط
create or replace function public.loyalty_save_settings(p_needed int, p_reward text, p_active boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.loyalty_settings;
begin
  if not private.dd_is_admin() then raise exception 'إعدادات البطاقة للمدير فقط.' using errcode = '42501'; end if;
  if p_needed is null or p_needed < 2 or p_needed > 30 then raise exception 'عدد الأختام بين 2 و 30.'; end if;
  if char_length(btrim(coalesce(p_reward, ''))) < 1 or char_length(btrim(p_reward)) > 60 then raise exception 'اكتب الهدية (حتى 60 حرف).'; end if;
  update public.loyalty_settings
     set stamps_needed = p_needed, reward = btrim(p_reward), active = coalesce(p_active, true), updated_at = now()
   where restaurant_id = private.dd_staff_restaurant()
  returning * into s;
  return to_jsonb(s);
end $$;

-- ---------- صلاحيات الدوال ----------
revoke all on function public.loyalty_join(uuid, text, text), public.loyalty_card(text), public.loyalty_find(text),
  public.loyalty_stamp(text, int), public.loyalty_unstamp(text), public.loyalty_redeem(text),
  public.loyalty_save_settings(int, text, boolean) from public, anon, authenticated;
grant execute on function public.loyalty_join(uuid, text, text), public.loyalty_card(text) to anon, authenticated;
grant execute on function public.loyalty_find(text), public.loyalty_stamp(text, int), public.loyalty_unstamp(text),
  public.loyalty_redeem(text), public.loyalty_save_settings(int, text, boolean) to authenticated;
