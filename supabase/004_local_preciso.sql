-- =====================================================================
-- Bilhetinho · Coração · migração 004: precisão do local da festa
-- Rode DEPOIS do 003_mensagens.sql. Cole no SQL Editor do Supabase > Run.
--
-- * Guarda a margem de erro (em metros) do aparelho que registrou o local.
-- * Na entrada do coração, desconta a margem do celular da pessoa e a do
--   local (cada uma até 300 m). O raio continua 200 m.
-- * O erro "longe_da_festa" passa a dizer a distância, para ajudar.
-- =====================================================================

alter table public.events add column if not exists venue_acc double precision;

drop function if exists public.set_venue_location(uuid, double precision, double precision);

create or replace function public.set_venue_location(
  p_event uuid, p_lat double precision, p_lng double precision, p_accuracy double precision default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not can_manage(p_event) then raise exception 'sem_permissao'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'local_invalido'; end if;
  update events set venue_lat = p_lat, venue_lng = p_lng, venue_acc = p_accuracy, venue_set_at = now()
   where id = p_event;
end $$;

create or replace function public.heart_join(
  p_event uuid, p_lat double precision, p_lng double precision, p_accuracy double precision,
  p_nickname text, p_find_me text, p_gender text, p_interest text, p_adult boolean
) returns public.heart_profiles
language plpgsql security definer set search_path = public as $$
declare e events; dist double precision; d double precision; prof heart_profiles;
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
  dist := distance_m(e.venue_lat, e.venue_lng, p_lat, p_lng);
  d := dist - least(greatest(coalesce(p_accuracy, 0), 0), 300) - least(greatest(coalesce(e.venue_acc, 0), 0), 300);
  if d > 200 then raise exception 'longe_da_festa:%', round(dist); end if;

  insert into heart_profiles (event_id, user_id, nickname, find_me, gender, interest)
  values (p_event, auth.uid(), trim(p_nickname), trim(coalesce(p_find_me, '')), p_gender, p_interest)
  on conflict (event_id, user_id) do update
    set nickname = excluded.nickname, find_me = excluded.find_me,
        gender = excluded.gender, interest = excluded.interest
  returning * into prof;
  return prof;
end $$;

revoke execute on function public.set_venue_location(uuid, double precision, double precision, double precision) from public, anon;
grant execute on function public.set_venue_location(uuid, double precision, double precision, double precision) to authenticated;
