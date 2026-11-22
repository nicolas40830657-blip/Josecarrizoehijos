-- Recomendaciones entre clientes, solicitudes de servicio y premio por recomendar

-- 1) Código para recomendar (distinto del código de acceso, que es privado)
alter table public.clientes add column if not exists ref text;
alter table public.clientes add column if not exists referido_por uuid references public.clientes(id) on delete set null;
update public.clientes set ref = upper(substr(md5(random()::text || id::text), 1, 6)) where ref is null;
alter table public.clientes alter column ref set default upper(substr(md5(random()::text), 1, 6));
create unique index if not exists clientes_ref on public.clientes (ref);

-- 2) Ajustes que configura el coordinador (ej: el premio por recomendar)
create table if not exists public.ajustes (
  clave text primary key,
  valor jsonb not null default '{}',
  actualizado timestamptz not null default now()
);
alter table public.ajustes enable row level security;
drop policy if exists equipo_lee on public.ajustes;
create policy equipo_lee on public.ajustes for select to authenticated using (es_equipo());
drop policy if exists gestor_escribe on public.ajustes;
create policy gestor_escribe on public.ajustes for all to authenticated using (es_gestor()) with check (es_gestor());
grant select, insert, update on public.ajustes to authenticated;
insert into public.ajustes (clave, valor) values ('premio_recomendar', '{"activo": false, "texto": ""}') on conflict do nothing;

-- 3) Solicitudes de servicio (de personas que todavía no son clientes)
create table if not exists public.solicitudes (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users on delete cascade,
  nombre text not null, telefono text not null, direccion text not null,
  lat double precision, lng double precision,
  tamano text, frecuencia text, comentario text,
  referido_por uuid references public.clientes(id) on delete set null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aceptada', 'rechazada')),
  respuesta text, cliente_id uuid references public.clientes(id) on delete set null,
  atendido_por uuid, creado timestamptz not null default now(), actualizado timestamptz
);
create index if not exists solicitudes_estado on public.solicitudes (estado, creado desc);
create index if not exists solicitudes_usuario on public.solicitudes (usuario_id, creado desc);
alter table public.solicitudes enable row level security;
drop policy if exists propia on public.solicitudes;
create policy propia on public.solicitudes for select to authenticated using (usuario_id = auth.uid());
drop policy if exists equipo_ve on public.solicitudes;
create policy equipo_ve on public.solicitudes for select to authenticated using (es_equipo());
revoke all on public.solicitudes from anon;
grant select on public.solicitudes to authenticated;

-- 4) Premios para quien recomienda (se generan con la primera visita del recomendado)
create table if not exists public.premios (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id) on delete cascade,   -- el que recomendó
  referido_id uuid not null unique references public.clientes(id) on delete cascade,  -- el nuevo cliente
  texto text not null,
  estado text not null default 'disponible' check (estado in ('disponible', 'entregado')),
  creado timestamptz not null default now(), entregado timestamptz, entregado_por uuid
);
alter table public.premios enable row level security;
drop policy if exists equipo_ve on public.premios;
create policy equipo_ve on public.premios for select to authenticated using (es_equipo());
revoke all on public.premios from anon;
grant select on public.premios to authenticated;

-- 5) Catálogo (precios reales) — lo usa la app del cliente y la muestra pública
create or replace function public.catalogo()
returns json language sql stable security definer set search_path = public as $$
  select coalesce((select json_agg(z order by z.promo desc, (z.pack_cant is not null) desc, z.t desc, z.nombre) from (
    select 'p' as t, pr.id, pr.nombre, pr.detalle,
           case when promo_vigente(pr.promo, pr.promo_hasta) and pr.promo_precio is not null then pr.promo_precio else pr.precio end as precio,
           pr.precio as precio_lista, promo_vigente(pr.promo, pr.promo_hasta) as promo,
           case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_regalo end as regalo,
           case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_texto end as promo_texto,
           case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_hasta end as promo_hasta,
           (pr.stock > 0) as hay, pr.pack_cant, case when pr.pack_cant is not null then pr.pack_desc end as pack_desc
      from productos pr where pr.tienda and coalesce(pr.precio, 0) > 0
    union all
    select 'k', k.id, k.nombre,
           (select string_agg(coalesce(pp.nombre, '?') || ' ×' || (i->>'n'), ', ')
              from jsonb_array_elements(k.items) i left join productos pp on pp.id = (i->>'p')::uuid),
           case when promo_vigente(k.promo, k.promo_hasta) and k.promo_precio is not null then k.promo_precio else k.precio end,
           k.precio, promo_vigente(k.promo, k.promo_hasta),
           case when promo_vigente(k.promo, k.promo_hasta) then k.promo_regalo end,
           case when promo_vigente(k.promo, k.promo_hasta) then k.promo_texto end,
           case when promo_vigente(k.promo, k.promo_hasta) then k.promo_hasta end,
           coalesce((select bool_and(coalesce(pp.stock, 0) >= (i->>'n')::numeric)
                       from jsonb_array_elements(k.items) i left join productos pp on pp.id = (i->>'p')::uuid), false),
           null::int, null::numeric
      from kits k where k.tienda and coalesce(k.precio, 0) > 0) z), '[]'::json);
$$;
revoke execute on function public.catalogo() from public, anon;
grant execute on function public.catalogo() to authenticated;

-- Para la muestra (sin cuenta): solo precios y productos, nada de clientes
create or replace function public.catalogo_publico()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('catalogo', catalogo(),
    'premio', (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar'));
$$;
grant execute on function public.catalogo_publico() to anon, authenticated;

-- 6) La app del cliente: ahora con su código para recomendar, sus premios y el premio vigente
create or replace function public.mi_pileta()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono,
                                 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia, 'ref', c.ref),
    'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color,
                                          'alias', p.pago_alias, 'cbu', p.pago_cbu, 'titular', p.pago_titular, 'banco', p.pago_banco)
                   from perfiles p where p.id = c.piletero_id),
    'visitas', coalesce((select json_agg(json_build_object('fecha', v.fecha, 'hora', v.hora, 'repetir', v.repetir, 'omitir', v.omitir))
                           from visitas v where v.cliente_id = c.id), '[]'::json),
    'realizadas', coalesce((select json_agg(x) from (
                     select r.id, r.fecha, r.valor, r.nota, r.productos, p.nombre as piletero
                       from realizadas r left join perfiles p on p.id = r.piletero_id
                      where r.cliente_id = c.id order by r.fecha desc limit 60) x), '[]'::json),
    'ventas', coalesce((select json_agg(y) from (
                 select s.id, s.fecha, s.nombre, s.cantidad, s.total, s.cobrado
                   from ventas s where s.cliente_id = c.id and not coalesce(s.anulada, false)
                  order by s.fecha desc, s.creado desc limit 40) y), '[]'::json),
    'catalogo', catalogo(),
    'recomendaciones', coalesce((select json_agg(w) from (
                   select r.id, r.tipo as t, r.item_id as id_item, r.cantidad, r.nota, r.creado,
                          coalesce(pr.nombre, k.nombre) as nombre, coalesce(pr.precio, k.precio) as precio
                     from recomendaciones r
                     left join productos pr on r.tipo = 'p' and pr.id = r.item_id
                     left join kits k on r.tipo = 'k' and k.id = r.item_id
                    where r.cliente_id = c.id and r.estado = 'activa' and coalesce(pr.id, k.id) is not null
                    order by r.creado desc) w), '[]'::json),
    'pedidos', coalesce((select json_agg(q) from (
                   select id, items, total, pago, nota, estado, creado from pedidos
                    where cliente_id = c.id order by creado desc limit 20) q), '[]'::json),
    'premios', coalesce((select json_agg(pm) from (
                   select pz.id, pz.texto, pz.estado, pz.creado, split_part(rc.nombre, ' ', 1) as referido
                     from premios pz join clientes rc on rc.id = pz.referido_id
                    where pz.cliente_id = c.id order by pz.creado desc limit 20) pm), '[]'::json),
    'premio_recomendar', (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar')
  )
  from clientes c where c.usuario_id = auth.uid() order by c.creado limit 1;
$$;

-- 7) Pedir el servicio (persona con cuenta, que todavía no es cliente)
create or replace function public.pedir_servicio(p_nombre text, p_telefono text, p_direccion text, p_lat double precision default null,
  p_lng double precision default null, p_tamano text default null, p_frecuencia text default null, p_comentario text default null, p_ref text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; ref_id uuid;
begin
  if auth.uid() is null then raise exception 'Primero creá tu cuenta'; end if;
  if es_equipo() then raise exception 'Esta es una cuenta del equipo. Usá otra cuenta para pedir el servicio.'; end if;
  if mi_cliente_id() is not null then raise exception 'Ya tenés tu pileta en la app'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 or length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) < 8 or length(trim(coalesce(p_direccion, ''))) < 4 then
    raise exception 'Completá tu nombre, un teléfono válido y la dirección';
  end if;
  if (select count(*) from solicitudes where usuario_id = auth.uid() and creado > now() - interval '1 day') >= 3 then
    raise exception 'Ya mandaste varias solicitudes hoy. Te vamos a contactar.';
  end if;
  select id into ref_id from clientes where ref = upper(trim(coalesce(p_ref, '')));
  select id into sid from solicitudes where usuario_id = auth.uid() and estado = 'pendiente' order by creado desc limit 1;
  if sid is not null then
    update solicitudes set nombre = left(trim(p_nombre), 80), telefono = left(trim(p_telefono), 30), direccion = left(trim(p_direccion), 150),
      lat = p_lat, lng = p_lng, tamano = left(p_tamano, 40), frecuencia = left(p_frecuencia, 40), comentario = left(p_comentario, 500),
      referido_por = coalesce(referido_por, ref_id), actualizado = now() where id = sid;
    return sid;
  end if;
  insert into solicitudes (usuario_id, nombre, telefono, direccion, lat, lng, tamano, frecuencia, comentario, referido_por)
  values (auth.uid(), left(trim(p_nombre), 80), left(trim(p_telefono), 30), left(trim(p_direccion), 150), p_lat, p_lng,
          left(p_tamano, 40), left(p_frecuencia, 40), left(p_comentario, 500), ref_id)
  returning id into sid;
  return sid;
end $$;
revoke execute on function public.pedir_servicio(text, text, text, double precision, double precision, text, text, text, text) from public, anon;
grant execute on function public.pedir_servicio(text, text, text, double precision, double precision, text, text, text, text) to authenticated;

create or replace function public.mi_solicitud()
returns json language sql stable security definer set search_path = public as $$
  select row_to_json(x) from (select id, nombre, direccion, estado, respuesta, creado from solicitudes
                               where usuario_id = auth.uid() order by creado desc limit 1) x;
$$;
revoke execute on function public.mi_solicitud() from public, anon;
grant execute on function public.mi_solicitud() to authenticated;

-- 8) El coordinador acepta: se crea el cliente ya vinculado a la cuenta de la persona
create or replace function public.aceptar_solicitud(p_id uuid, p_piletero uuid, p_valor numeric default 0, p_frecuencia text default 'Semanal', p_dia text default 'Sin día fijo',
  p_lat double precision default null, p_lng double precision default null, p_direccion text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s solicitudes; cid uuid;
begin
  if not es_gestor() then raise exception 'Solo un coordinador puede aceptar solicitudes'; end if;
  select * into s from solicitudes where id = p_id for update;
  if s.id is null or s.estado <> 'pendiente' then raise exception 'Esa solicitud ya fue respondida'; end if;
  if not exists (select 1 from perfiles where id = p_piletero and activo) then raise exception 'Elegí un piletero del equipo'; end if;
  if exists (select 1 from clientes where usuario_id = s.usuario_id) then raise exception 'Esa cuenta ya tiene una pileta vinculada'; end if;
  if coalesce(p_lat, s.lat) is null or coalesce(p_lng, s.lng) is null then raise exception 'No pude ubicar la dirección en el mapa. Corregila.'; end if;
  insert into clientes (nombre, direccion, telefono, lat, lng, piletero_id, valor_visita, frecuencia, dia, usuario_id, codigo, referido_por)
  values (s.nombre, coalesce(nullif(trim(p_direccion), ''), s.direccion), s.telefono, coalesce(p_lat, s.lat), coalesce(p_lng, s.lng), p_piletero, coalesce(p_valor, 0), coalesce(p_frecuencia, 'Semanal'), coalesce(p_dia, 'Sin día fijo'),
          s.usuario_id, upper(substr(md5(random()::text), 1, 6)), s.referido_por)
  returning id into cid;
  update solicitudes set estado = 'aceptada', cliente_id = cid, atendido_por = auth.uid(), actualizado = now() where id = p_id;
  return cid;
end $$;
revoke execute on function public.aceptar_solicitud(uuid, uuid, numeric, text, text, double precision, double precision, text) from public, anon;
grant execute on function public.aceptar_solicitud(uuid, uuid, numeric, text, text, double precision, double precision, text) to authenticated;

create or replace function public.rechazar_solicitud(p_id uuid, p_respuesta text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_gestor() then raise exception 'Solo un coordinador puede responder solicitudes'; end if;
  update solicitudes set estado = 'rechazada', respuesta = left(nullif(trim(coalesce(p_respuesta, '')), ''), 300), atendido_por = auth.uid(), actualizado = now()
   where id = p_id and estado = 'pendiente';
  if not found then raise exception 'Esa solicitud ya fue respondida'; end if;
end $$;
revoke execute on function public.rechazar_solicitud(uuid, text) from public, anon;
grant execute on function public.rechazar_solicitud(uuid, text) to authenticated;

-- 9) Premio: cuando el recomendado tiene su PRIMERA visita hecha
create or replace function public.dar_premio_recomendado()
returns trigger language plpgsql security definer set search_path = public as $$
declare quien uuid; txt text;
begin
  select referido_por into quien from clientes where id = new.cliente_id;
  if quien is null or exists (select 1 from premios where referido_id = new.cliente_id) then return null; end if;
  select case when (valor->>'activo')::boolean then nullif(trim(valor->>'texto'), '') end into txt from ajustes where clave = 'premio_recomendar';
  if txt is null then return null; end if;
  insert into premios (cliente_id, referido_id, texto) values (quien, new.cliente_id, txt) on conflict (referido_id) do nothing;
  return null;
exception when others then return null;
end $$;
revoke execute on function public.dar_premio_recomendado() from public, anon, authenticated;
drop trigger if exists premio_recomendado on public.realizadas;
create trigger premio_recomendado after insert on public.realizadas for each row execute function dar_premio_recomendado();

create or replace function public.entregar_premio(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update premios set estado = 'entregado', entregado = now(), entregado_por = auth.uid()
   where id = p_id and estado = 'disponible' and atiende(cliente_id);
  if not found then raise exception 'No se pudo marcar el premio'; end if;
end $$;
revoke execute on function public.entregar_premio(uuid) from public, anon;
grant execute on function public.entregar_premio(uuid) to authenticated;

-- 10) Notificaciones: también para quien espera la respuesta de su solicitud
create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_app text, p_prefs jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  if p_app = 'equipo' and not es_equipo() then raise exception 'Cuenta no habilitada'; end if;
  if p_app = 'cliente' and mi_cliente_id() is null and not exists (select 1 from solicitudes where usuario_id = auth.uid()) then raise exception 'Primero vinculá tu pileta'; end if;
  if p_app not in ('equipo', 'cliente') or coalesce(p_endpoint, '') !~ '^https://' then raise exception 'Datos inválidos'; end if;
  delete from push_subs where endpoint = p_endpoint;
  insert into push_subs (usuario_id, app, endpoint, p256dh, auth, prefs)
  values (auth.uid(), p_app, p_endpoint, p_p256dh, p_auth, coalesce(p_prefs, '{}'));
end $$;

drop trigger if exists push_solicitud_nueva on public.solicitudes;
create trigger push_solicitud_nueva after insert on public.solicitudes for each row execute function avisar_push();
drop trigger if exists push_solicitud_estado on public.solicitudes;
create trigger push_solicitud_estado after update of estado on public.solicitudes for each row
  when (old.estado is distinct from new.estado) execute function avisar_push();
drop trigger if exists push_premio on public.premios;
create trigger push_premio after insert on public.premios for each row execute function avisar_push();
