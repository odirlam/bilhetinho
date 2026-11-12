-- =====================================================================
-- Bilhetinho · banco de dados v1 (versão de teste)
-- Cole tudo isto no Supabase: SQL Editor > New query > Run.
--
-- Ideia geral:
--  * Todo mundo pode LER eventos e pedidos (é uma fila pública da festa).
--  * Ninguém escreve direto nas tabelas. Toda escrita passa por funções
--    (create_request, toggle_vote, set_status...) que conferem as regras.
--  * A plateia entra com login anônimo (sem cadastro), um por aparelho.
--  * A banda entra com e-mail. O tablet do palco é anônimo, mas ganha
--    permissão quando a banda aprova o pareamento.
-- =====================================================================

-- ---------- Tabelas ----------

create table public.bands (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 2 and 60),
  created_at  timestamptz not null default now()
);

create table public.events (
  id          uuid primary key default gen_random_uuid(),
  band_id     uuid not null references public.bands(id) on delete cascade,
  slug        text not null unique,
  name        text not null check (char_length(name) between 2 and 60),
  venue       text not null default '' check (char_length(venue) <= 60),
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  pix_mode    text not null default 'prioridade' check (pix_mode in ('destaque','prioridade','furafila')),
  ff_price    int  not null default 30 check (ff_price between 5 and 500),
  ff_limit    int  not null default 2  check (ff_limit between 1 and 20),
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index events_band_idx on public.events (band_id, starts_at);

create table public.requests (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  user_id     uuid not null,
  song        text not null check (char_length(song) between 1 and 100),
  artist      text not null default '' check (char_length(artist) <= 80),
  from_name   text not null check (char_length(from_name) between 1 and 30),
  mesa        text not null default '' check (char_length(mesa) <= 6),
  message     text not null default '' check (char_length(message) <= 80),
  votes       int  not null default 1,
  status      text not null default 'fila' check (status in ('fila','tocando','tocada','nao')),
  tip         int  not null default 0 check (tip between 0 and 500),
  tip_status  text not null default 'none' check (tip_status in ('none','pending','paid')),
  mode        text not null,             -- regra do Pix que valia quando o pedido foi feito
  ff          boolean not null default false,  -- pedido com fura-fila
  created_at  timestamptz not null default now()
);
create index requests_event_idx on public.requests (event_id, status);

create table public.votes (
  request_id  uuid not null references public.requests(id) on delete cascade,
  user_id     uuid not null,
  primary key (request_id, user_id)
);

create table public.pairings (
  code        text primary key,
  tablet_uid  uuid not null,
  event_id    uuid references public.events(id) on delete cascade,
  approved_at timestamptz,
  expires_at  timestamptz not null
);
create index pairings_tablet_idx on public.pairings (tablet_uid);

-- ---------- Quem pode ler ----------

alter table public.bands    enable row level security;
alter table public.events   enable row level security;
alter table public.requests enable row level security;
alter table public.votes    enable row level security;
alter table public.pairings enable row level security;

create policy "bandas visiveis"   on public.bands    for select using (true);
create policy "eventos visiveis"  on public.events   for select using (true);
create policy "pedidos visiveis"  on public.requests for select using (true);
create policy "meus votos"        on public.votes    for select using (user_id = auth.uid());
create policy "meu pareamento"    on public.pairings for select using (tablet_uid = auth.uid());
-- Sem políticas de insert/update/delete: só as funções abaixo escrevem.

-- ---------- Ajudantes ----------

-- Texto sem acento, minúsculo, para comparar nomes de música.
create or replace function public.norm(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(lower(translate(coalesce(t,''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9]+', ' ', 'g'))
$$;

-- Usuário com e-mail (não anônimo).
create or replace function public.is_real_user() returns boolean
language sql stable as $$
  select auth.uid() is not null
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
$$;

-- Pode comandar o palco deste evento: a banda dona ou um tablet pareado.
create or replace function public.can_manage(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from events e where e.id = p_event and e.band_id = auth.uid())
      or exists (select 1 from pairings p where p.event_id = p_event
                   and p.tablet_uid = auth.uid() and p.approved_at is not null)
$$;

-- ---------- Banda e eventos ----------

create or replace function public.save_band(p_name text) returns public.bands
language plpgsql security definer set search_path = public as $$
declare b bands;
begin
  if not is_real_user() then raise exception 'precisa_login'; end if;
  insert into bands (id, name) values (auth.uid(), trim(p_name))
  on conflict (id) do update set name = excluded.name
  returning * into b;
  return b;
end $$;

create or replace function public.create_event(
  p_name text, p_venue text, p_starts timestamptz, p_ends timestamptz,
  p_pix_mode text, p_ff_price int, p_ff_limit int
) returns public.events
language plpgsql security definer set search_path = public as $$
declare e events; s text;
begin
  if not is_real_user() then raise exception 'precisa_login'; end if;
  if not exists (select 1 from bands where id = auth.uid()) then raise exception 'sem_banda'; end if;
  s := regexp_replace(norm(p_name), ' ', '-', 'g') || '-' ||
       substr(replace(gen_random_uuid()::text, '-', ''), 1, 4);
  insert into events (band_id, slug, name, venue, starts_at, ends_at, pix_mode, ff_price, ff_limit)
  values (auth.uid(), s, trim(p_name), trim(coalesce(p_venue,'')), p_starts, p_ends,
          p_pix_mode, coalesce(p_ff_price, 30), coalesce(p_ff_limit, 2))
  returning * into e;
  return e;
end $$;

-- Muda a regra do Pix. Vale só para pedidos novos (cada pedido guarda a sua).
create or replace function public.update_event_rules(p_event uuid, p_pix_mode text, p_ff_price int, p_ff_limit int)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e events;
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  update events set pix_mode = p_pix_mode, ff_price = p_ff_price, ff_limit = p_ff_limit
  where id = p_event returning * into e;
  return e;
end $$;

-- ---------- Pedidos e votos ----------

create or replace function public.create_request(
  p_event uuid, p_song text, p_artist text, p_from text, p_mesa text,
  p_message text, p_tip int, p_ff boolean
) returns json
language plpgsql security definer set search_path = public as $$
declare
  e events; dup requests; r requests;
  v_tip int := greatest(coalesce(p_tip, 0), 0);
  v_ff boolean := coalesce(p_ff, false);
  inserted int;
begin
  if auth.uid() is null then raise exception 'precisa_login'; end if;
  select * into e from events where id = p_event;
  if not found then raise exception 'evento_nao_encontrado'; end if;
  if now() < e.starts_at - interval '3 hours' or now() > e.ends_at + interval '1 hour' then
    raise exception 'evento_fechado';
  end if;
  if (select count(*) from requests where event_id = p_event and user_id = auth.uid()
        and created_at > now() - interval '10 minutes') >= 5 then
    raise exception 'muitos_pedidos';
  end if;

  -- Música já pedida: soma o voto em vez de duplicar.
  select * into dup from requests
   where event_id = p_event and status in ('fila','tocando') and norm(song) = norm(p_song)
   order by created_at limit 1;
  if found then
    if dup.status = 'tocando' then
      return json_build_object('action','playing','request_id',dup.id,'votes',dup.votes);
    end if;
    insert into votes (request_id, user_id) values (dup.id, auth.uid()) on conflict do nothing;
    get diagnostics inserted = row_count;
    if inserted = 0 then
      return json_build_object('action','already_voted','request_id',dup.id,'votes',dup.votes);
    end if;
    update requests set votes = votes + 1 where id = dup.id returning * into dup;
    return json_build_object('action','voted','request_id',dup.id,'votes',dup.votes);
  end if;

  -- Fura-fila: só quando a regra do evento é fura-fila, com valor e limite da banda.
  if v_ff and e.pix_mode <> 'furafila' then v_ff := false; end if;
  if v_ff then
    v_tip := e.ff_price;
    if (select count(*) from requests where event_id = p_event and ff and tip_status <> 'none'
          and created_at > now() - interval '1 hour') >= e.ff_limit then
      raise exception 'furafila_esgotado';
    end if;
  elsif v_tip not in (0, 5, 10, 20) then
    raise exception 'valor_invalido';
  end if;

  insert into requests (event_id, user_id, song, artist, from_name, mesa, message,
                        tip, tip_status, mode, ff)
  values (p_event, auth.uid(), trim(p_song), trim(coalesce(p_artist,'')), trim(p_from),
          trim(coalesce(p_mesa,'')), trim(coalesce(p_message,'')),
          v_tip, case when v_tip > 0 then 'pending' else 'none' end, e.pix_mode, v_ff)
  returning * into r;
  insert into votes (request_id, user_id) values (r.id, auth.uid());
  return json_build_object('action','created','request_id',r.id,'votes',1,'tip',v_tip,'ff',v_ff);
end $$;

create or replace function public.toggle_vote(p_request uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r requests; had boolean;
begin
  if auth.uid() is null then raise exception 'precisa_login'; end if;
  select * into r from requests where id = p_request;
  if not found or r.status <> 'fila' then raise exception 'pedido_fechado'; end if;
  delete from votes where request_id = p_request and user_id = auth.uid();
  had := found;
  if had then
    update requests set votes = greatest(votes - 1, 0) where id = p_request returning * into r;
  else
    insert into votes (request_id, user_id) values (p_request, auth.uid());
    update requests set votes = votes + 1 where id = p_request returning * into r;
  end if;
  return json_build_object('votes', r.votes, 'voted', not had);
end $$;

-- Palco: "Vou tocar", "Não tenho", "Tocada".
create or replace function public.set_status(p_request uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare v_event uuid;
begin
  select event_id into v_event from requests where id = p_request;
  if v_event is null or not can_manage(v_event) then raise exception 'sem_permissao'; end if;
  if p_status = 'tocando' then
    update requests set status = 'tocada'
     where event_id = v_event and status = 'tocando' and id <> p_request;
  end if;
  update requests set status = p_status where id = p_request;
end $$;

-- PIX SIMULADO: marca como pago. Na versão com Pix de verdade, quem chama
-- isto é o aviso (webhook) do provedor de pagamento, não o celular da pessoa.
create or replace function public.simulate_payment(p_request uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update requests set tip_status = 'paid'
   where id = p_request and user_id = auth.uid() and tip_status = 'pending';
end $$;

-- ---------- Pareamento do tablet ----------

-- O tablet pede um código novo (vale 40 segundos).
create or replace function public.start_pairing() returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'precisa_login'; end if;
  delete from pairings where tablet_uid = auth.uid() and approved_at is null;
  c := substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
  insert into pairings (code, tablet_uid, expires_at) values (c, auth.uid(), now() + interval '40 seconds');
  return c;
end $$;

-- O celular da banda (logado) aprova o código lido no tablet.
create or replace function public.approve_pairing(p_code text, p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_real_user() then raise exception 'precisa_login'; end if;
  if not exists (select 1 from events where id = p_event and band_id = auth.uid()) then
    raise exception 'sem_permissao';
  end if;
  update pairings set event_id = p_event, approved_at = now()
   where code = p_code and approved_at is null and expires_at > now();
  if not found then raise exception 'codigo_expirado'; end if;
end $$;

-- ---------- Permissões das funções ----------

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.norm(text), public.is_real_user(), public.can_manage(uuid),
  public.save_band(text),
  public.create_event(text, text, timestamptz, timestamptz, text, int, int),
  public.update_event_rules(uuid, text, int, int),
  public.create_request(uuid, text, text, text, text, text, int, boolean),
  public.toggle_vote(uuid), public.set_status(uuid, text),
  public.simulate_payment(uuid), public.start_pairing(), public.approve_pairing(text, uuid)
to authenticated;

-- ---------- Tempo real ----------

alter publication supabase_realtime add table public.requests, public.events, public.pairings;
