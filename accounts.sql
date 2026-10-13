-- Poker Nights: save each signed-in person's groups to their account.
-- Run once in the Supabase SQL editor, after schema.sql.

create table if not exists public.pn_user_groups (
  user_id  uuid not null references auth.users(id) on delete cascade,
  code     text not null references public.pn_groups(code) on delete cascade,
  secret   text,                                   -- edit secret, when this person has edit access
  added_at timestamptz not null default now(),
  primary key (user_id, code)
);
alter table public.pn_user_groups enable row level security;
revoke all on public.pn_user_groups from anon, authenticated;

-- The signed-in person's groups. Secrets that were rotated since come back as null.
create or replace function public.pn_my_groups() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'code', u.code,
           'secret', case when u.secret = g.edit_secret then u.secret else null end)
         order by u.added_at), '[]'::json)
  from pn_user_groups u join pn_groups g on g.code = u.code
  where u.user_id = auth.uid()
$$;

-- Add groups to the signed-in person's account: [{ code, secret? }]. Only real groups,
-- and only valid secrets, are kept. Never downgrades a saved edit secret to watch-only.
create or replace function public.pn_save_groups(p_list jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  insert into pn_user_groups(user_id, code, secret)
  select uid, g.code, case when g.edit_secret = x ->> 'secret' then g.edit_secret else null end
  from jsonb_array_elements(p_list) x
  join pn_groups g on g.code = x ->> 'code'
  on conflict (user_id, code) do update
    set secret = coalesce(excluded.secret, pn_user_groups.secret);
end $$;

-- Remove one group from the signed-in person's account (the group itself is untouched).
create or replace function public.pn_forget_group(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from pn_user_groups where user_id = auth.uid() and code = p_code;
end $$;

revoke all on function public.pn_my_groups(), public.pn_save_groups(jsonb), public.pn_forget_group(text) from public, anon;
grant execute on function public.pn_my_groups(), public.pn_save_groups(jsonb), public.pn_forget_group(text) to authenticated;
