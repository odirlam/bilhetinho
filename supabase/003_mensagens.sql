-- =====================================================================
-- Bilhetinho · Coração · migração 003: mais mensagens prontas
-- Rode DEPOIS do 002_coracao.sql. Cole no SQL Editor do Supabase > Run.
--
-- Convites: drink, bar, dancar, oi, foto, onde, musica
-- Respostas, conforme o convite:
--   drink  -> drink_sim, sem_alcool, depois, nao
--   bar    -> indo, mesa, depois, nao
--   dancar -> dancar_sim, proxima, depois, nao
--   oi     -> tambem, oi_volta, nao
--   foto   -> foto_sim, depois, nao
--   onde   -> mesa, acha, nao
--   musica -> amei, obrigado
-- "mesa" leva o número da mesa; "acha" leva o "como me achar" do perfil;
-- "musica" aponta para um pedido de música feito por quem envia.
-- =====================================================================

alter table public.heart_messages add column if not exists extra text not null default '';
alter table public.heart_messages drop constraint if exists heart_messages_extra_check;
alter table public.heart_messages add constraint heart_messages_extra_check check (char_length(extra) <= 100);

alter table public.heart_messages drop constraint if exists heart_messages_kind_check;
alter table public.heart_messages add constraint heart_messages_kind_check check (kind in (
  'drink','bar','dancar','oi','foto','onde','musica',
  'sim','nao','depois','drink_sim','sem_alcool','indo','mesa','dancar_sim','proxima',
  'tambem','oi_volta','foto_sim','acha','amei','obrigado'));

drop function if exists public.heart_send(uuid, text);

create or replace function public.heart_send(p_match uuid, p_kind text, p_extra text default '')
returns public.heart_messages
language plpgsql security definer set search_path = public as $$
declare
  m heart_matches; other uuid; msg heart_messages; v_extra text := ''; r requests; mine heart_profiles;
  asks text[] := array['drink','bar','dancar','oi','foto','onde','musica'];
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
  elsif p_kind = 'mesa' then
    if coalesce(p_extra, '') !~ '^[0-9A-Za-z]{1,6}$' then raise exception 'mesa_invalida'; end if;
    v_extra := p_extra;
  elsif p_kind = 'acha' then
    select * into mine from heart_profiles where event_id = m.event_id and user_id = auth.uid();
    if coalesce(mine.find_me, '') = '' then raise exception 'sem_como_achar'; end if;
    v_extra := mine.find_me;
  elsif p_kind = 'musica' then
    begin
      select * into r from requests where id = p_extra::uuid and user_id = auth.uid() and event_id = m.event_id;
    exception when invalid_text_representation then r := null;
    end;
    if r.id is null then raise exception 'pedido_invalido'; end if;
    v_extra := left(r.song, 100);
  end if;

  -- Respostas só depois de a outra pessoa ter mandado algo.
  if not (p_kind = any(asks))
     and not exists (select 1 from heart_messages where match_id = p_match and from_user = other) then
    raise exception 'nada_para_responder';
  end if;

  insert into heart_messages (match_id, from_user, kind, extra)
  values (p_match, auth.uid(), p_kind, v_extra) returning * into msg;
  return msg;
end $$;

revoke execute on function public.heart_send(uuid, text, text) from public, anon;
grant execute on function public.heart_send(uuid, text, text) to authenticated;
