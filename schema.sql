-- Poker Nights database setup. Run once in the Supabase SQL editor.
--
-- Security model: nobody logs in. Each group has a short public code (the watch link)
-- and a long secret (the edit link). The tables are locked: the browser can't read or
-- write them directly. Everything goes through the functions below, which check the
-- code for reads and the code + secret for writes.

create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------------

create table if not exists public.pn_groups (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  edit_secret text not null,
  name        text not null,
  players     jsonb not null default '{}'::jsonb,   -- { pid: { name, aliases[], color, createdAt } }
  created_at  bigint not null default (extract(epoch from now()) * 1000)::bigint
);

create table if not exists public.pn_nights (
  id          text primary key,
  group_id    uuid not null references public.pn_groups(id) on delete cascade,
  name        text not null default '',
  unit        integer not null default 500,
  status      text not null default 'open' check (status in ('open', 'settled')),
  started_at  bigint not null,
  settled_at  bigint,
  seats       jsonb not null default '[]'::jsonb,   -- [ { pid, cashOut } ]
  summary     jsonb                                  -- { pid: { in, out } } once closed
);
create index if not exists pn_nights_group_idx on public.pn_nights(group_id);

create table if not exists public.pn_events (
  id        text primary key,
  night_id  text not null references public.pn_nights(id) on delete cascade,
  pid       text not null,
  amount    integer not null,                        -- negative = negative buy-in
  note      text not null default '',
  at        bigint not null
);
create index if not exists pn_events_night_idx on public.pn_events(night_id);

alter table public.pn_groups enable row level security;
alter table public.pn_nights enable row level security;
alter table public.pn_events enable row level security;
revoke all on public.pn_groups, public.pn_nights, public.pn_events from anon, authenticated;

-- ------------------------------------------------------------------
-- Internal helpers (not callable from the browser)
-- ------------------------------------------------------------------

create or replace function public.pn_rand(n int) returns text
language sql volatile set search_path = public, extensions as $$
  select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', (get_byte(b, i) % 31) + 1, 1), '' order by i)
  from (select gen_random_bytes(n) as b) s, generate_series(0, n - 1) i
$$;

create or replace function public.pn_auth(p_code text, p_secret text) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  select id into gid from pn_groups where code = p_code and edit_secret = p_secret;
  if gid is null then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return gid;
end $$;

create or replace function public.pn_night_of(p_gid uuid, p_night text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pn_nights where id = p_night and group_id = p_gid) then
    raise exception 'night_not_found' using errcode = 'P0002';
  end if;
end $$;

revoke all on function public.pn_rand(int), public.pn_auth(text, text), public.pn_night_of(uuid, text) from public, anon, authenticated;

-- ------------------------------------------------------------------
-- Reads
-- ------------------------------------------------------------------

-- Everything about one group: the group, its nights and every buy-in.
create or replace function public.pn_get(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'group', json_build_object('code', g.code, 'name', g.name, 'players', g.players, 'createdAt', g.created_at),
    'nights', coalesce((
      select json_agg(json_build_object(
        'id', n.id, 'name', n.name, 'unit', n.unit, 'status', n.status,
        'startedAt', n.started_at, 'settledAt', n.settled_at, 'seats', n.seats, 'summary', n.summary))
      from pn_nights n where n.group_id = g.id), '[]'::json),
    'events', coalesce((
      select json_agg(json_build_object(
        'id', e.id, 'nightId', e.night_id, 'pid', e.pid, 'amount', e.amount, 'note', e.note, 'at', e.at))
      from pn_events e join pn_nights n on n.id = e.night_id where n.group_id = g.id), '[]'::json)
  )
  from pn_groups g where g.code = p_code
$$;

-- True when this secret is the group's edit secret.
create or replace function public.pn_can_edit(p_code text, p_secret text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pn_groups where code = p_code and edit_secret = p_secret)
$$;

-- ------------------------------------------------------------------
-- Writes (all need the edit secret)
-- ------------------------------------------------------------------

create or replace function public.pn_create_group(p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare c text; s text;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'name_required'; end if;
  loop
    c := pn_rand(10);
    exit when not exists (select 1 from pn_groups where code = c);
  end loop;
  s := pn_rand(24);
  insert into pn_groups(code, edit_secret, name) values (c, s, left(trim(p_name), 80));
  return json_build_object('code', c, 'secret', s);
end $$;

-- Rename the group and/or merge player changes: { pid: { name?, aliases?, color? } }.
create or replace function public.pn_group_update(p_code text, p_secret text, p_name text default null, p_players jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  update pn_groups g set
    name = coalesce(nullif(left(trim(p_name), 80), ''), g.name),
    players = case when p_players is null then g.players else g.players || (
      select coalesce(jsonb_object_agg(k, coalesce(g.players -> k, '{}'::jsonb) || v), '{}'::jsonb)
      from jsonb_each(p_players) as t(k, v)) end
  where g.id = gid;
end $$;

create or replace function public.pn_night_create(p_code text, p_secret text, p_id text, p_unit int, p_pids jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret); now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  insert into pn_nights(id, group_id, unit, started_at, seats)
  values (p_id, gid, p_unit, now_ms,
    coalesce((select jsonb_agg(jsonb_build_object('pid', x, 'cashOut', null)) from jsonb_array_elements_text(p_pids) x), '[]'::jsonb));
  insert into pn_events(id, night_id, pid, amount, note, at)
  select p_id || '-' || x, p_id, x, p_unit, 'Buy-in', now_ms from jsonb_array_elements_text(p_pids) x;
end $$;

-- Change name, unit, status, settledAt or summary. Only the keys present are changed.
create or replace function public.pn_night_patch(p_code text, p_secret text, p_night text, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  perform pn_night_of(gid, p_night);
  update pn_nights set
    name       = case when p_patch ? 'name' then left(coalesce(p_patch ->> 'name', ''), 80) else name end,
    unit       = case when p_patch ? 'unit' then (p_patch ->> 'unit')::int else unit end,
    status     = case when p_patch ? 'status' then p_patch ->> 'status' else status end,
    settled_at = case when p_patch ? 'settledAt' then (p_patch ->> 'settledAt')::bigint else settled_at end,
    summary    = case when p_patch ? 'summary' then p_patch -> 'summary' else summary end
  where id = p_night;
end $$;

create or replace function public.pn_night_delete(p_code text, p_secret text, p_night text) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  delete from pn_nights where id = p_night and group_id = gid;
end $$;

-- Seat a player and give them their first buy-in.
create or replace function public.pn_seat_add(p_code text, p_secret text, p_night text, p_pid text, p_event text) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret); u int;
begin
  perform pn_night_of(gid, p_night);
  update pn_nights set seats = seats || jsonb_build_array(jsonb_build_object('pid', p_pid, 'cashOut', null))
  where id = p_night and not exists (select 1 from jsonb_array_elements(seats) s where s ->> 'pid' = p_pid)
  returning unit into u;
  if u is not null then
    insert into pn_events(id, night_id, pid, amount, note, at)
    values (p_event, p_night, p_pid, u, 'Buy-in', (extract(epoch from now()) * 1000)::bigint);
  end if;
end $$;

create or replace function public.pn_seat_remove(p_code text, p_secret text, p_night text, p_pid text) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  perform pn_night_of(gid, p_night);
  update pn_nights set seats = coalesce((
    select jsonb_agg(s order by o) from jsonb_array_elements(seats) with ordinality t(s, o) where s ->> 'pid' <> p_pid), '[]'::jsonb)
  where id = p_night;
  delete from pn_events where night_id = p_night and pid = p_pid;
end $$;

-- Set (or clear, with null) one player's chip count at the end.
create or replace function public.pn_seat_cash(p_code text, p_secret text, p_night text, p_pid text, p_cash int) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  perform pn_night_of(gid, p_night);
  update pn_nights set seats = coalesce((
    select jsonb_agg(case when s ->> 'pid' = p_pid then jsonb_set(s, '{cashOut}', coalesce(to_jsonb(p_cash), 'null'::jsonb)) else s end order by o)
    from jsonb_array_elements(seats) with ordinality t(s, o)), '[]'::jsonb)
  where id = p_night;
end $$;

create or replace function public.pn_event_add(p_code text, p_secret text, p_night text, p_id text, p_pid text, p_amount int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  perform pn_night_of(gid, p_night);
  insert into pn_events(id, night_id, pid, amount, note, at)
  values (p_id, p_night, p_pid, p_amount, left(coalesce(p_note, ''), 120), (extract(epoch from now()) * 1000)::bigint);
end $$;

create or replace function public.pn_event_delete(p_code text, p_secret text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid := pn_auth(p_code, p_secret);
begin
  delete from pn_events e using pn_nights n
  where e.id = p_id and n.id = e.night_id and n.group_id = gid;
end $$;

-- ------------------------------------------------------------------
-- Who can call what
-- ------------------------------------------------------------------

revoke all on function
  public.pn_get(text), public.pn_can_edit(text, text), public.pn_create_group(text),
  public.pn_group_update(text, text, text, jsonb),
  public.pn_night_create(text, text, text, int, jsonb), public.pn_night_patch(text, text, text, jsonb),
  public.pn_night_delete(text, text, text),
  public.pn_seat_add(text, text, text, text, text), public.pn_seat_remove(text, text, text, text),
  public.pn_seat_cash(text, text, text, text, int),
  public.pn_event_add(text, text, text, text, text, int, text), public.pn_event_delete(text, text, text)
from public;

grant execute on function
  public.pn_get(text), public.pn_can_edit(text, text), public.pn_create_group(text),
  public.pn_group_update(text, text, text, jsonb),
  public.pn_night_create(text, text, text, int, jsonb), public.pn_night_patch(text, text, text, jsonb),
  public.pn_night_delete(text, text, text),
  public.pn_seat_add(text, text, text, text, text), public.pn_seat_remove(text, text, text, text),
  public.pn_seat_cash(text, text, text, text, int),
  public.pn_event_add(text, text, text, text, text, int, text), public.pn_event_delete(text, text, text)
to anon, authenticated;
