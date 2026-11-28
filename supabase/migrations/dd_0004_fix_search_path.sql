-- طُبّق على قاعدة Daily Dose بتاريخ 2026-11-28
-- تثبيت search_path للدوال اللي كانت بدونه (تحذير أمني من Supabase)
alter function public.client_ip() set search_path = public, pg_temp;
alter function public.my_ip() set search_path = public, pg_temp;
alter function public.sync_order_items_and_total() set search_path = public, pg_temp;
alter function public.get_current_user_restaurant_id() set search_path = public, pg_temp;
-- دالة قديمة غير مستخدمة بالكود: ممنوعة على الزوار
revoke execute on function public.get_current_user_restaurant_id() from public, anon;
