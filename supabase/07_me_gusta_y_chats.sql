-- "Me gusta" del cliente en las fotos de su pileta + resumen de chats para la app del equipo

create table if not exists public.me_gusta (
  id uuid primary key default gen_random_uuid(),
  foto_id uuid not null unique references public.fotos(id) on delete cascade,
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  usuario_id uuid default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists me_gusta_cliente on public.me_gusta (cliente_id);
alter table public.me_gusta enable row level security;
drop policy if exists equipo_ve on public.me_gusta;
create policy equipo_ve on public.me_gusta for select to authenticated using (es_equipo());
revoke all on public.me_gusta from anon;
grant select on public.me_gusta to authenticated;

-- El cliente da o saca "me gusta" a una foto de SU pileta
create or replace function public.dar_me_gusta(p_foto uuid, p_si boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c uuid := mi_cliente_id();
begin
  if c is null or not exists (select 1 from fotos where id = p_foto and cliente_id = c) then
    raise exception 'Esa foto no es de tu pileta';
  end if;
  if p_si then
    insert into me_gusta (foto_id, cliente_id) values (p_foto, c) on conflict (foto_id) do nothing;
  else
    delete from me_gusta where foto_id = p_foto and cliente_id = c;
  end if;
  return p_si;
end $$;
revoke execute on function public.dar_me_gusta(uuid, boolean) from public, anon;
grant execute on function public.dar_me_gusta(uuid, boolean) to authenticated;

-- Las fotos del cliente ahora dicen si le dio "me gusta"
create or replace function public.mi_fotos(p_limite integer default 6)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select f.id, f.realizada_id, f.data, f.creado,
           exists (select 1 from me_gusta g where g.foto_id = f.id) as gusta
      from fotos f
     where f.cliente_id = mi_cliente_id()
     order by f.creado desc limit least(coalesce(p_limite, 6), 100)) x;
$$;

-- Aviso al piletero cuando al cliente le gusta la foto
drop trigger if exists push_me_gusta on public.me_gusta;
create trigger push_me_gusta after insert on public.me_gusta for each row execute function avisar_push();

-- Último mensaje de cada chat (sin traer las fotos) y cuántos no leyó el equipo.
-- Corre con los permisos de quien la llama: cada uno ve solo los chats que ya puede ver.
create index if not exists mensajes_cliente_creado on public.mensajes (cliente_id, creado desc);
create or replace function public.resumen_chats()
returns table (cliente_id uuid, creado timestamptz, texto text, foto boolean, de_cliente boolean, sin_leer integer)
language sql stable security invoker set search_path = public as $$
  select distinct on (m.cliente_id) m.cliente_id, m.creado, left(m.texto, 160), m.foto is not null, m.de_cliente,
         (select count(*) from mensajes x where x.cliente_id = m.cliente_id and x.de_cliente and not x.leido_equipo)::int
    from mensajes m
   order by m.cliente_id, m.creado desc;
$$;
revoke execute on function public.resumen_chats() from public, anon;
grant execute on function public.resumen_chats() to authenticated;
