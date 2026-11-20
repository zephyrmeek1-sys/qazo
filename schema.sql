-- QAZO — Supabase SQL (SQL Editor'ga to'liq qo'yib Run bosing)
-- XAVFSIZ: bu fayl qayta Run qilinsa ham ma'lumotlar o'chmaydi (faqat "if not exists" / "or replace" ishlatiladi).
-- Foydalanuvchi ma'lumotlari va rasmlar Supabase'da saqlanadi, index.html ni butunlay almashtirsangiz ham yo'qolmaydi.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.admins(user_id uuid primary key references auth.users on delete cascade);

create table if not exists public.profiles(
  user_id uuid primary key references auth.users on delete cascade,
  phone text unique not null, name text,
  gender text check (gender in ('male','female')),
  birth_date date, prayer_from date, start_date date,
  married boolean default false, hayz_days int default 0, children int default 0,
  nifas_days int default 0, preg_months int default 0,
  city text default 'Tashkent', asr_school int default 1,
  lang text default 'uz', theme text default 'auto',
  created_at timestamptz default now());

alter table public.profiles add column if not exists pregnancies int[] default '{}';
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists notify boolean default false;
alter table public.profiles add column if not exists notify_prefs jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists daily_target int not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='profiles_daily_target_chk') then
    alter table public.profiles add constraint profiles_daily_target_chk check (daily_target between 1 and 3);
  end if;
end $$;

-- Adminga yozilgan so'rovlar (parolni unutgan va h.k.)
create table if not exists public.support_requests(
  id bigserial primary key, created_at timestamptz default now(),
  user_id uuid references auth.users on delete set null,
  name text not null, phone text not null, reason text not null, message text,
  status text not null default 'new' check (status in ('new','done')));
alter table public.support_requests enable row level security;
revoke all on public.support_requests from anon, authenticated;

create table if not exists public.qazo_balance(
  user_id uuid references auth.users on delete cascade,
  prayer text check (prayer in ('bomdod','peshin','asr','shom','xufton','vitr')),
  initial int not null default 0 check (initial >= 0),
  primary key(user_id, prayer));

-- bir kun + bir namoz = bitta yozuv (takroriy ayirishdan himoya)
create table if not exists public.prayer_log(
  user_id uuid references auth.users on delete cascade, day date, prayer text,
  created_at timestamptz default now(), primary key(user_id, day, prayer));
create table if not exists public.qazo_log(
  user_id uuid references auth.users on delete cascade, day date, prayer text,
  slot int not null default 1,
  created_at timestamptz default now(), primary key(user_id, day, prayer, slot));
-- eski jadval (slot'siz) bo'lsa, ma'lumotni saqlagan holda yangilash
alter table public.qazo_log add column if not exists slot int not null default 1;
do $$ begin
  if exists (select 1 from pg_constraint where conrelid='public.qazo_log'::regclass and contype='p' and array_length(conkey,1)=3) then
    alter table public.qazo_log drop constraint qazo_log_pkey;
    alter table public.qazo_log add primary key (user_id, day, prayer, slot);
  end if;
end $$;
create table if not exists public.hayz_log(
  user_id uuid references auth.users on delete cascade, day date,
  primary key(user_id, day));
create table if not exists public.audit_log(
  id bigserial primary key, user_id uuid references auth.users on delete cascade,
  action text, detail jsonb, created_at timestamptz default now());

-- RLS: har kim faqat o'zinikini ko'radi; yozish faqat funksiyalar orqali
alter table public.admins enable row level security;
alter table public.profiles enable row level security;
alter table public.qazo_balance enable row level security;
alter table public.prayer_log enable row level security;
alter table public.qazo_log enable row level security;
alter table public.hayz_log enable row level security;
alter table public.audit_log enable row level security;

do $$ declare t text; begin
  foreach t in array array['profiles','qazo_balance','prayer_log','qazo_log','hayz_log','audit_log'] loop
    execute format('drop policy if exists own_select on public.%I', t);
    execute format('create policy own_select on public.%I for select to authenticated using (user_id = auth.uid())', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
revoke all on public.admins from anon, authenticated;
drop policy if exists own_update on public.profiles;
create policy own_update on public.profiles for update to authenticated using (user_id = auth.uid());
grant update (name, city, asr_school, lang, theme, avatar_url, notify, notify_prefs, daily_target) on public.profiles to authenticated;

-- Qazo hisoblash + profil saqlash (server tomonda, deterministik)
drop function if exists public.setup_profile(text,text,date,date,date,boolean,int,int,int,int);
create or replace function public.setup_profile(
  p_name text, p_gender text, p_birth date, p_prayer_from date, p_start date,
  p_married boolean, p_hayz int, p_children int, p_nifas int, p_preg_list int[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s date; e date; d int; ex int := 0; mth numeric; n int; ph text; pr text;
        pl int[]; pm int := 0;
begin
  if uid is null then raise exception 'auth'; end if;
  if p_gender not in ('male','female') then raise exception 'gender'; end if;
  if p_birth is null or p_prayer_from is null then raise exception 'dates'; end if;
  pl := coalesce(p_preg_list, '{}');
  if not coalesce(p_married,false) or p_gender <> 'female' then pl := '{}'; end if;
  if exists (select 1 from unnest(pl) x where x < 0 or x > 12) then raise exception 'pregnancy'; end if;
  pm := coalesce((select sum(x) from unnest(pl) x), 0);
  s := coalesce(p_start, (p_birth + (case when p_gender='male' then 12 else 9 end) * interval '1 year')::date + 1);
  e := p_prayer_from - 1;
  d := greatest(e - s + 1, 0);
  if p_gender = 'female' then
    mth := d / 30.4375;
    ex := least(d, (round(greatest(mth - pm, 0) * least(greatest(coalesce(p_hayz,0),0),15))
          + coalesce(p_children,0) * least(greatest(coalesce(p_nifas,0),0),60))::int);
  end if;
  n := d - ex;
  select split_part(email,'@',1) into ph from auth.users where id = uid;
  insert into profiles(user_id, phone, name, gender, birth_date, prayer_from, start_date, married, hayz_days, children, nifas_days, preg_months, pregnancies)
  values (uid, ph, nullif(p_name,''), p_gender, p_birth, p_prayer_from, s, coalesce(p_married,false), p_hayz, p_children, p_nifas, pm, pl)
  on conflict (user_id) do update set name=excluded.name, gender=excluded.gender, birth_date=excluded.birth_date,
    prayer_from=excluded.prayer_from, start_date=excluded.start_date, married=excluded.married,
    hayz_days=excluded.hayz_days, children=excluded.children, nifas_days=excluded.nifas_days,
    preg_months=excluded.preg_months, pregnancies=excluded.pregnancies;
  foreach pr in array array['bomdod','peshin','asr','shom','xufton','vitr'] loop
    insert into qazo_balance(user_id, prayer, initial) values (uid, pr, n)
    on conflict (user_id, prayer) do update set initial = excluded.initial;
  end loop;
  insert into audit_log(user_id, action, detail) values (uid, 'setup',
    jsonb_build_object('start', s, 'end', e, 'days', d, 'excluded', ex, 'per_prayer', n, 'pregnancies', pl));
  return jsonb_build_object('start', s, 'end', e, 'days', d, 'excluded', ex, 'per_prayer', n);
end $$;

-- Belgilash / qaytarish (kind: prayer | qazo | hayz)
create or replace function public.toggle_item(p_kind text, p_prayer text, p_day date, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rem int;
begin
  if uid is null then raise exception 'auth'; end if;
  if p_day > current_date + 1 then raise exception 'future'; end if;
  if p_kind = 'qazo' then
    if p_on then
      select b.initial - (select count(*) from qazo_log q where q.user_id=uid and q.prayer=p_prayer) into rem
        from qazo_balance b where b.user_id=uid and b.prayer=p_prayer;
      if coalesce(rem,0) <= 0 then raise exception 'empty'; end if;
      insert into qazo_log(user_id, day, prayer) values (uid, p_day, p_prayer) on conflict do nothing;
    else delete from qazo_log where user_id=uid and day=p_day and prayer=p_prayer; end if;
  elsif p_kind = 'prayer' then
    if p_on then insert into prayer_log(user_id, day, prayer) values (uid, p_day, p_prayer) on conflict do nothing;
    else delete from prayer_log where user_id=uid and day=p_day and prayer=p_prayer; end if;
  elsif p_kind = 'hayz' then
    if p_on then
      insert into hayz_log(user_id, day) values (uid, p_day) on conflict do nothing;
      delete from prayer_log where user_id=uid and day=p_day;
    else delete from hayz_log where user_id=uid and day=p_day; end if;
  else raise exception 'kind'; end if;
  insert into audit_log(user_id, action, detail) values (uid, p_kind, jsonb_build_object('prayer',p_prayer,'day',p_day,'on',p_on));
end $$;

-- Balans va statistika (jadvaldan hisoblanadi, qo'lda yuritilgan jami yo'q)
create or replace function public.qazo_stats() returns jsonb
language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'bal', coalesce((select jsonb_object_agg(b.prayer, jsonb_build_object('initial', b.initial,
        'done', (select count(*) from qazo_log q where q.user_id=b.user_id and q.prayer=b.prayer)))
      from qazo_balance b where b.user_id=auth.uid()), '{}'::jsonb),
    'last30', (select count(*) from qazo_log where user_id=auth.uid() and day > current_date - 30),
    'week', coalesce((select jsonb_agg(jsonb_build_object('day', g::date,
        'qazo', (select count(*) from qazo_log q where q.user_id=auth.uid() and q.day=g::date),
        'prayer', (select count(*) from prayer_log p where p.user_id=auth.uid() and p.day=g::date)) order by g)
      from generate_series(date_trunc('week', current_date), date_trunc('week', current_date) + interval '6 days', interval '1 day') g), '[]'::jsonb));
$$;

-- ADMIN
create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as
$$ select exists(select 1 from admins where user_id = auth.uid()) $$;



-- Parol hech qachon ko'rsatilmaydi (hash). Admin faqat yangi parol qo'ya oladi.
create or replace function public.admin_reset_password(p_user uuid, p_pass text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  if length(p_pass) < 6 then raise exception 'short'; end if;
  update auth.users set encrypted_password = crypt(p_pass, gen_salt('bf')), updated_at = now() where id = p_user;
end $$;

create or replace function public.admin_delete_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  delete from auth.users where id = p_user;
end $$;

-- Bir kunda bir nechta qazo: p_count = shu kuni shu namozdan o'qilgan jami qazo soni
create or replace function public.set_qazo(p_prayer text, p_day date, p_count int)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cur int; rem int;
begin
  if uid is null then raise exception 'auth'; end if;
  if p_day > current_date + 1 then raise exception 'future'; end if;
  if p_prayer not in ('bomdod','peshin','asr','shom','xufton','vitr') then raise exception 'prayer'; end if;
  if p_count < 0 or p_count > 20 then raise exception 'count'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text || p_prayer));
  select count(*) into cur from qazo_log where user_id=uid and day=p_day and prayer=p_prayer;
  if p_count > cur then
    select b.initial - (select count(*) from qazo_log q where q.user_id=uid and q.prayer=p_prayer) into rem
      from qazo_balance b where b.user_id=uid and b.prayer=p_prayer;
    if coalesce(rem,0) < p_count - cur then raise exception 'empty'; end if;
  end if;
  delete from qazo_log where user_id=uid and day=p_day and prayer=p_prayer and slot > p_count;
  insert into qazo_log(user_id, day, prayer, slot)
    select uid, p_day, p_prayer, g from generate_series(1, p_count) g on conflict do nothing;
  insert into audit_log(user_id, action, detail) values (uid, 'qazo',
    jsonb_build_object('prayer', p_prayer, 'day', p_day, 'count', p_count, 'on', p_count >= cur));
end $$;

-- Adminga yozish (ro'yxatdan o'tmagan foydalanuvchi ham yubora oladi; spamdan himoya bilan)
create or replace function public.submit_support(p_name text, p_phone text, p_reason text, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  if length(trim(coalesce(p_name,''))) < 2 or length(p_name) > 80 then raise exception 'name'; end if;
  if length(ph) < 9 or length(ph) > 15 then raise exception 'phone'; end if;
  if p_reason not in ('password','login','calc','idea','other') then raise exception 'reason'; end if;
  if length(coalesce(p_message,'')) > 500 then raise exception 'long'; end if;
  if (select count(*) from support_requests where phone = ph and created_at > now() - interval '1 hour') >= 5 then raise exception 'rate'; end if;
  insert into support_requests(user_id, name, phone, reason, message)
  values (auth.uid(), trim(p_name), ph, p_reason, nullif(trim(coalesce(p_message,'')), ''));
end $$;

-- ADMIN: umumiy ko'rsatkichlar
create or replace function public.admin_overview() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'not admin'; end if;
  with u as (select id, created_at, last_sign_in_at from auth.users where id not in (select user_id from admins))
  select jsonb_build_object(
    'users', (select count(*) from u),
    'new_today', (select count(*) from u where created_at >= date_trunc('day', now())),
    'new_7d', (select count(*) from u where created_at > now() - interval '7 days'),
    'active_7d', (select count(*) from u where last_sign_in_at > now() - interval '7 days'),
    'male', (select count(*) from profiles p join u on u.id=p.user_id where p.gender='male'),
    'female', (select count(*) from profiles p join u on u.id=p.user_id where p.gender='female'),
    'remaining', (select coalesce(sum(b.initial),0) from qazo_balance b join u on u.id=b.user_id)
                 - (select count(*) from qazo_log q join u on u.id=q.user_id),
    'done', (select count(*) from qazo_log q join u on u.id=q.user_id),
    'done_today', (select count(*) from qazo_log q join u on u.id=q.user_id where q.day = current_date),
    'done_7d', (select count(*) from qazo_log q join u on u.id=q.user_id where q.day > current_date - 7),
    'requests_new', (select count(*) from support_requests where status='new'),
    'reg14', (select coalesce(jsonb_agg(jsonb_build_object('day', g::date, 'n', (select count(*) from u where u.created_at::date = g::date)) order by g), '[]'::jsonb)
              from generate_series(current_date - 13, current_date, interval '1 day') g)
  ) into r;
  return r;
end $$;

drop function if exists public.admin_users();
create or replace function public.admin_users()
returns table(user_id uuid, phone text, name text, gender text, created_at timestamptz, last_sign_in timestamptz,
              remaining bigint, done bigint, target int, city text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  return query select u.id, split_part(u.email,'@',1)::text, p.name::text, p.gender::text, u.created_at, u.last_sign_in_at,
    (coalesce((select sum(b.initial) from qazo_balance b where b.user_id=u.id),0)
      - (select count(*) from qazo_log q where q.user_id=u.id))::bigint,
    (select count(*) from qazo_log q where q.user_id=u.id)::bigint,
    p.daily_target, p.city::text
  from auth.users u left join profiles p on p.user_id=u.id
  where not exists (select 1 from admins a where a.user_id=u.id) order by u.created_at desc;
end $$;

create or replace function public.admin_user_detail(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'not admin'; end if;
  select jsonb_build_object('profile', to_jsonb(p) - 'user_id' - 'hayz_days' - 'pregnancies' - 'preg_months' - 'nifas_days' - 'married' - 'children' - 'notify_prefs',
    'phone', p.phone,
    'bal', coalesce((select jsonb_object_agg(b.prayer, jsonb_build_object('initial', b.initial,
        'done', (select count(*) from qazo_log q where q.user_id=b.user_id and q.prayer=b.prayer)))
        from qazo_balance b where b.user_id=p_user), '{}'::jsonb),
    'recent', coalesce((select jsonb_agg(x) from (select action, detail, created_at from audit_log
        where user_id=p_user and action <> 'hayz' order by created_at desc limit 15) x), '[]'::jsonb))
  into r from profiles p where p.user_id = p_user;
  return coalesce(r, '{}'::jsonb);
end $$;

create or replace function public.admin_requests()
returns table(id bigint, created_at timestamptz, name text, phone text, reason text, message text, status text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  return query select s.id, s.created_at, s.name, s.phone, s.reason, s.message, s.status
    from support_requests s order by (s.status = 'new') desc, s.created_at desc limit 200;
end $$;

create or replace function public.admin_set_request(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  if p_status not in ('new','done') then raise exception 'status'; end if;
  update support_requests set status = p_status where id = p_id;
end $$;

create or replace function public.admin_activity(p_limit int default 60)
returns table(created_at timestamptz, phone text, action text, detail jsonb)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not admin'; end if;
  return query select a.created_at, split_part(u.email,'@',1)::text, a.action::text, a.detail
    from audit_log a join auth.users u on u.id = a.user_id
    where not exists (select 1 from admins ad where ad.user_id = a.user_id) and a.action <> 'hayz'
    order by a.created_at desc limit least(greatest(p_limit,1), 200);
end $$;


do $$ declare f text; begin
  foreach f in array array['setup_profile(text,text,date,date,date,boolean,int,int,int,int[])','toggle_item(text,text,date,boolean)',
    'qazo_stats()','is_admin()','admin_users()','admin_reset_password(uuid,text)','admin_delete_user(uuid)',
    'set_qazo(text,date,int)','admin_overview()','admin_user_detail(uuid)','admin_requests()','admin_set_request(bigint,text)','admin_activity(int)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

revoke all on function public.submit_support(text,text,text,text) from public;
grant execute on function public.submit_support(text,text,text,text) to anon, authenticated;

-- ADMIN QO'SHISH: avval Authentication > Users'da email+parol bilan user yarating,
-- so'ng emailni o'zgartirib shu qatorni alohida Run qiling:
-- insert into public.admins select id from auth.users where email = 'SIZNING@gmail.com';

-- RASMLAR (Supabase Storage). Har foydalanuvchi faqat o'z papkasiga (uning id si) yoza oladi.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars','avatars', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists avatars_read on storage.objects;
drop policy if exists avatars_insert on storage.objects;
drop policy if exists avatars_update on storage.objects;
drop policy if exists avatars_delete on storage.objects;
create policy avatars_read on storage.objects for select using (bucket_id = 'avatars');
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
