-- =====================================================================
-- Bilhetinho · Coração (fase 2) · migração 002
-- Rode DEPOIS do schema.sql. Cole tudo no SQL Editor do Supabase > Run.
--
-- Regras combinadas em 25/11/2026:
--  * Só entra quem declara ter 18 anos ou mais e está no local da festa
--    (localização do celular, com tolerância para a margem de erro do GPS).
--  * Foto obrigatória (selfie), guardada em espaço privado.
--  * Cada um só vê quem combina com "sou" e "quero conhecer".
--  * Conversa só depois do match, por mensagens prontas.
--  * Até 5 convites de drink por noite (enviados), 1 por pessoa.
--  * Denunciar e bloquear; 2 denúncias tiram o perfil da festa, e a banda
--    ou o organizador também pode remover.
--  * Nada disso aparece fora do horário da festa.
-- =====================================================================

-- ---------- Local da festa (registrado pelo tablet do palco) ----------

alter table public.events
  add column if not exists venue_lat double precision,
  add column if not exists venue_lng double precision,
  add column if not exists venue_set_at timestamptz;

create or replace function public.set_venue_location(p_event uuid, p_lat double precision, p_lng double precision)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'local_invalido'; end if;
  update events set venue_lat = p_lat, venue_lng = p_lng, venue_set_at = now() where id = p_event;
end $$;

-- ---------- Tabelas ----------

create table public.heart_profiles (
  event_id    uuid not null references public.events(id) on delete cascade,
  user_id     uuid not null,
  nickname    text not null check (char_length(nickname) between 2 and 20),
  find_me     text not null default '' check (char_length(find_me) <= 60),
  gender      text not null check (gender in ('mulher','homem','nao_binario')),
  interest    text not null check (interest in ('mulheres','homens','todos')),
  has_photo   boolean not null default false,
  hidden      boolean not null default false,   -- removido por denúncias ou pelo organizador
  created_at  timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table public.heart_likes (
  event_id    uuid not null references public.events(id) on delete cascade,
  from_user   uuid not null,
  to_user     uuid not null,
  liked       boolean not null,               -- false = passou
  created_at  timestamptz not null default now(),
  primary key (event_id, from_user, to_user)
);

create table public.heart_matches (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  user_a      uuid not null,
  user_b      uuid not null,
  created_at  timestamptz not null default now(),
  check (user_a < user_b),
  unique (event_id, user_a, user_b)
);

create table public.heart_messages (
  id          uuid primary key default gen_random_uuid(),
  match_id    uuid not null references public.heart_matches(id) on delete cascade,
  from_user   uuid not null,
  kind        text not null check (kind in ('drink','bar','dancar','oi','sim','nao')),
  created_at  timestamptz not null default now()
);
create index heart_messages_match_idx on public.heart_messages (match_id, created_at);

create table public.heart_blocks (
  event_id    uuid not null references public.events(id) on delete cascade,
  from_user   uuid not null,
  to_user     uuid not null,
  is_report   boolean not null default false,
  reason      text not null default '' check (char_length(reason) <= 100),
  created_at  timestamptz not null default now(),
  primary key (event_id, from_user, to_user)
);

-- ---------- Quem pode ler ----------

alter table public.heart_profiles enable row level security;
alter table public.heart_likes    enable row level security;
alter table public.heart_matches  enable row level security;
alter table public.heart_messages enable row level security;
alter table public.heart_blocks   enable row level security;

-- Perfil: o próprio e os de quem deu match com você. A lista de "Conhecer"
-- vem da função heart_deck, nunca de uma leitura direta da tabela.
create policy "meu perfil e meus matches" on public.heart_profiles for select using (
  user_id = auth.uid() or exists (
    select 1 from public.heart_matches m
     where m.event_id = heart_profiles.event_id
       and ((m.user_a = auth.uid() and m.user_b = heart_profiles.user_id)
         or (m.user_b = auth.uid() and m.user_a = heart_profiles.user_id))));
create policy "meus matches" on public.heart_matches for select using (auth.uid() in (user_a, user_b));
create policy "mensagens dos meus matches" on public.heart_messages for select using (
  exists (select 1 from public.heart_matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));
-- heart_likes e heart_blocks: ninguém lê direto.

-- ---------- Ajudantes ----------

create or replace function public.heart_event_open(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from events e where e.id = p_event
    and now() between e.starts_at - interval '3 hours' and e.ends_at + interval '1 hour')
$$;

-- "sou" x "quero conhecer"
create or replace function public.heart_compat(p_gender text, p_interest text) returns boolean
language sql immutable as $$
  select p_interest = 'todos'
      or (p_interest = 'mulheres' and p_gender = 'mulher')
      or (p_interest = 'homens'   and p_gender = 'homem')
$$;

create or replace function public.heart_blocked(p_event uuid, a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from heart_blocks k where k.event_id = p_event
    and ((k.from_user = a and k.to_user = b) or (k.from_user = b and k.to_user = a)))
$$;

-- Distância em metros entre dois pontos (fórmula de haversine).
create or replace function public.distance_m(lat1 double precision, lng1 double precision,
                                             lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- ---------- Entrar no coração ----------

-- A localização só é usada para esta conferência: não é guardada.
create or replace function public.heart_join(
  p_event uuid, p_lat double precision, p_lng double precision, p_accuracy double precision,
  p_nickname text, p_find_me text, p_gender text, p_interest text, p_adult boolean
) returns public.heart_profiles
language plpgsql security definer set search_path = public as $$
declare e events; d double precision; prof heart_profiles;
begin
  if auth.uid() is null then raise exception 'precisa_login'; end if;
  if not coalesce(p_adult, false) then raise exception 'menor_de_idade'; end if;
  select * into e from events where id = p_event;
  if not found then raise exception 'evento_nao_encontrado'; end if;
  if not heart_event_open(p_event) then raise exception 'evento_fechado'; end if;
  if e.venue_lat is null then raise exception 'local_nao_definido'; end if;
  if exists (select 1 from heart_profiles where event_id = p_event and user_id = auth.uid() and hidden) then
    raise exception 'removido';
  end if;
  -- Raio de 200 m, descontando a margem de erro que o celular informa (até 300 m).
  d := distance_m(e.venue_lat, e.venue_lng, p_lat, p_lng) - least(greatest(coalesce(p_accuracy, 0), 0), 300);
  if d > 200 then raise exception 'longe_da_festa'; end if;

  insert into heart_profiles (event_id, user_id, nickname, find_me, gender, interest)
  values (p_event, auth.uid(), trim(p_nickname), trim(coalesce(p_find_me, '')), p_gender, p_interest)
  on conflict (event_id, user_id) do update
    set nickname = excluded.nickname, find_me = excluded.find_me,
        gender = excluded.gender, interest = excluded.interest
  returning * into prof;
  return prof;
end $$;

-- Chamada depois de enviar a selfie.
create or replace function public.heart_photo_ready(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update heart_profiles set has_photo = true where event_id = p_event and user_id = auth.uid();
  if not found then raise exception 'sem_perfil'; end if;
end $$;

-- Sair do coração: apaga o perfil, as curtidas e os matches desta pessoa.
create or replace function public.heart_leave(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from heart_likes where event_id = p_event and (from_user = auth.uid() or to_user = auth.uid());
  delete from heart_matches where event_id = p_event and auth.uid() in (user_a, user_b);
  delete from heart_profiles where event_id = p_event and user_id = auth.uid() and not hidden;
end $$;

-- ---------- Conhecer ----------

-- Quem eu posso ver: combina nos dois sentidos, tem foto, não foi removido,
-- sem bloqueio entre nós, e ainda não curti nem passei.
create or replace function public.heart_deck(p_event uuid)
returns table (user_id uuid, nickname text, find_me text)
language plpgsql stable security definer set search_path = public as $$
declare me heart_profiles;
begin
  select * into me from heart_profiles hp where hp.event_id = p_event and hp.user_id = auth.uid();
  if not found or me.hidden or not me.has_photo or not heart_event_open(p_event) then return; end if;
  return query
    select p.user_id, p.nickname, p.find_me
      from heart_profiles p
     where p.event_id = p_event and p.user_id <> me.user_id
       and p.has_photo and not p.hidden
       and heart_compat(p.gender, me.interest) and heart_compat(me.gender, p.interest)
       and not heart_blocked(p_event, me.user_id, p.user_id)
       and not exists (select 1 from heart_likes l where l.event_id = p_event
                         and l.from_user = me.user_id and l.to_user = p.user_id)
     order by random()
     limit 30;
end $$;

-- Curtir (true) ou passar (false). Curtida dos dois lados vira match.
create or replace function public.heart_like(p_event uuid, p_to uuid, p_liked boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me heart_profiles; other heart_profiles; mid uuid; a uuid; b uuid;
begin
  select * into me from heart_profiles where event_id = p_event and user_id = auth.uid();
  if not found or me.hidden or not me.has_photo then raise exception 'sem_perfil'; end if;
  if not heart_event_open(p_event) then raise exception 'evento_fechado'; end if;
  select * into other from heart_profiles where event_id = p_event and user_id = p_to;
  if not found or other.hidden or p_to = me.user_id then raise exception 'perfil_indisponivel'; end if;
  if heart_blocked(p_event, me.user_id, p_to) then raise exception 'perfil_indisponivel'; end if;
  if (select count(*) from heart_likes where event_id = p_event and from_user = me.user_id
        and created_at > now() - interval '1 minute') >= 40 then
    raise exception 'calma';
  end if;

  insert into heart_likes (event_id, from_user, to_user, liked) values (p_event, me.user_id, p_to, p_liked)
  on conflict (event_id, from_user, to_user) do update set liked = excluded.liked, created_at = now();

  if p_liked and exists (select 1 from heart_likes where event_id = p_event
                          and from_user = p_to and to_user = me.user_id and liked) then
    a := least(me.user_id, p_to); b := greatest(me.user_id, p_to);
    insert into heart_matches (event_id, user_a, user_b) values (p_event, a, b)
    on conflict (event_id, user_a, user_b) do nothing;
    select id into mid from heart_matches where event_id = p_event and user_a = a and user_b = b;
    return json_build_object('match', true, 'match_id', mid);
  end if;
  return json_build_object('match', false);
end $$;

-- Meus matches com os dados de quem combinou comigo.
create or replace function public.heart_my_matches(p_event uuid)
returns table (match_id uuid, user_id uuid, nickname text, find_me text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, p.user_id, p.nickname, p.find_me, m.created_at
    from heart_matches m
    join heart_profiles p on p.event_id = m.event_id
     and p.user_id = case when m.user_a = auth.uid() then m.user_b else m.user_a end
   where m.event_id = p_event and auth.uid() in (m.user_a, m.user_b)
     and not p.hidden and not heart_blocked(p_event, m.user_a, m.user_b)
     and heart_event_open(p_event)
   order by m.created_at desc
$$;

-- ---------- Mensagens prontas ----------

create or replace function public.heart_send(p_match uuid, p_kind text) returns public.heart_messages
language plpgsql security definer set search_path = public as $$
declare m heart_matches; other uuid; msg heart_messages;
begin
  select * into m from heart_matches where id = p_match;
  if not found or auth.uid() not in (m.user_a, m.user_b) then raise exception 'sem_permissao'; end if;
  other := case when m.user_a = auth.uid() then m.user_b else m.user_a end;
  if not heart_event_open(m.event_id) then raise exception 'evento_fechado'; end if;
  if heart_blocked(m.event_id, auth.uid(), other)
     or exists (select 1 from heart_profiles where event_id = m.event_id and user_id in (auth.uid(), other) and hidden) then
    raise exception 'perfil_indisponivel';
  end if;
  if (select count(*) from heart_messages where match_id = p_match and from_user = auth.uid()
        and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'calma';
  end if;
  if p_kind = 'drink' then
    if exists (select 1 from heart_messages where match_id = p_match and from_user = auth.uid() and kind = 'drink') then
      raise exception 'drink_ja_enviado';
    end if;
    if (select count(*) from heart_messages hm join heart_matches mm on mm.id = hm.match_id
          where mm.event_id = m.event_id and hm.from_user = auth.uid() and hm.kind = 'drink') >= 5 then
      raise exception 'limite_drinks';
    end if;
  end if;
  if p_kind in ('sim','nao') and not exists (select 1 from heart_messages where match_id = p_match and from_user = other) then
    raise exception 'nada_para_responder';
  end if;
  insert into heart_messages (match_id, from_user, kind) values (p_match, auth.uid(), p_kind) returning * into msg;
  return msg;
end $$;

-- ---------- Bloquear e denunciar ----------

create or replace function public.heart_block(p_event uuid, p_user uuid, p_report boolean, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_user = auth.uid() then raise exception 'sem_permissao'; end if;
  insert into heart_blocks (event_id, from_user, to_user, is_report, reason)
  values (p_event, auth.uid(), p_user, coalesce(p_report, false), left(coalesce(p_reason, ''), 100))
  on conflict (event_id, from_user, to_user) do update
    set is_report = heart_blocks.is_report or excluded.is_report,
        reason = case when excluded.reason <> '' then excluded.reason else heart_blocks.reason end;
  -- Duas denúncias de pessoas diferentes tiram o perfil da festa.
  if (select count(*) from heart_blocks where event_id = p_event and to_user = p_user and is_report) >= 2 then
    update heart_profiles set hidden = true where event_id = p_event and user_id = p_user;
  end if;
end $$;

-- Para o palco: perfis denunciados.
create or replace function public.heart_reports(p_event uuid)
returns table (user_id uuid, nickname text, find_me text, reports bigint, reasons text, hidden boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  return query
    select p.user_id, p.nickname, p.find_me, count(*), string_agg(nullif(k.reason, ''), ' · '), p.hidden
      from heart_blocks k join heart_profiles p on p.event_id = k.event_id and p.user_id = k.to_user
     where k.event_id = p_event and k.is_report
     group by p.user_id, p.nickname, p.find_me, p.hidden
     order by count(*) desc;
end $$;

create or replace function public.heart_remove(p_event uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  update heart_profiles set hidden = true where event_id = p_event and user_id = p_user;
end $$;

-- Para o palco: quantas pessoas estão no coração e quantos matches houve.
create or replace function public.heart_stats(p_event uuid) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  return json_build_object(
    'perfis', (select count(*) from heart_profiles where event_id = p_event and has_photo and not hidden),
    'matches', (select count(*) from heart_matches where event_id = p_event));
end $$;

-- ---------- Fotos (privadas) ----------
-- Caminho: <id do evento>/<id da pessoa>/foto.jpg
-- Só quem está no coração do mesmo evento, com a festa aberta, consegue ver.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('heart-photos', 'heart-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create policy "coracao: enviar a propria foto" on storage.objects for insert to authenticated
with check (
  bucket_id = 'heart-photos'
  and (storage.foldername(name))[2] = auth.uid()::text
  and exists (select 1 from public.heart_profiles p
               where p.event_id::text = (storage.foldername(name))[1] and p.user_id = auth.uid() and not p.hidden));

create policy "coracao: trocar a propria foto" on storage.objects for update to authenticated
using (bucket_id = 'heart-photos' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "coracao: apagar a propria foto" on storage.objects for delete to authenticated
using (bucket_id = 'heart-photos' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "coracao: ver fotos da festa" on storage.objects for select to authenticated
using (
  bucket_id = 'heart-photos'
  and (
    (storage.foldername(name))[2] = auth.uid()::text
    or (exists (select 1 from public.heart_profiles p
                 where p.event_id::text = (storage.foldername(name))[1] and p.user_id = auth.uid() and not p.hidden)
        and public.heart_event_open(((storage.foldername(name))[1])::uuid))
    or public.can_manage(((storage.foldername(name))[1])::uuid)));

-- ---------- Permissões e tempo real ----------

revoke execute on function
  public.set_venue_location(uuid, double precision, double precision),
  public.heart_event_open(uuid), public.heart_compat(text, text), public.heart_blocked(uuid, uuid, uuid),
  public.distance_m(double precision, double precision, double precision, double precision),
  public.heart_join(uuid, double precision, double precision, double precision, text, text, text, text, boolean),
  public.heart_photo_ready(uuid), public.heart_leave(uuid), public.heart_deck(uuid),
  public.heart_like(uuid, uuid, boolean), public.heart_my_matches(uuid), public.heart_send(uuid, text),
  public.heart_block(uuid, uuid, boolean, text), public.heart_reports(uuid), public.heart_remove(uuid, uuid),
  public.heart_stats(uuid)
from public, anon;
grant execute on function
  public.set_venue_location(uuid, double precision, double precision),
  public.heart_event_open(uuid), public.heart_compat(text, text), public.heart_blocked(uuid, uuid, uuid),
  public.distance_m(double precision, double precision, double precision, double precision),
  public.heart_join(uuid, double precision, double precision, double precision, text, text, text, text, boolean),
  public.heart_photo_ready(uuid), public.heart_leave(uuid), public.heart_deck(uuid),
  public.heart_like(uuid, uuid, boolean), public.heart_my_matches(uuid), public.heart_send(uuid, text),
  public.heart_block(uuid, uuid, boolean, text), public.heart_reports(uuid), public.heart_remove(uuid, uuid),
  public.heart_stats(uuid)
to authenticated;

alter publication supabase_realtime add table public.heart_matches, public.heart_messages;
