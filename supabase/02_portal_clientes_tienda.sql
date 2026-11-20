-- ════════════════════════════════════════════════════════════════════
--  José Carrizo e Hijos · Portal de clientes + tienda
--  Proyecto Supabase gqromisweyqvdeeahxnl (app del equipo).
--  Todo es agregado: no borra ni cambia datos existentes. Se puede
--  correr más de una vez.
-- ════════════════════════════════════════════════════════════════════

-- 1) Código de acceso y cuenta vinculada en cada cliente
alter table public.clientes add column if not exists usuario_id uuid references auth.users(id) on delete set null;
alter table public.clientes add column if not exists codigo text;
update public.clientes set codigo = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 6)) where codigo is null;
alter table public.clientes alter column codigo set default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
create unique index if not exists clientes_codigo_key on public.clientes(codigo);
create index if not exists clientes_usuario_idx on public.clientes(usuario_id);

-- Productos y kits: si se muestran en la tienda de clientes
alter table public.productos add column if not exists tienda boolean not null default true;
alter table public.kits      add column if not exists tienda boolean not null default true;

-- 2) Funciones auxiliares
create or replace function public.es_equipo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid())
     and coalesce(auth.jwt() -> 'user_metadata' ->> 'tipo', '') <> 'cliente';
$$;

create or replace function public.mi_cliente_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from clientes where usuario_id = auth.uid() order by creado limit 1;
$$;

-- ¿El usuario del equipo puede atender a este cliente? (gestor o su piletero)
create or replace function public.atiende(p_cliente uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select es_equipo() and (es_gestor() or exists (select 1 from clientes where id = p_cliente and piletero_id = auth.uid()));
$$;

-- 3) Mensajes cliente ↔ equipo
create table if not exists public.mensajes (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  autor_id      uuid not null default auth.uid(),
  de_cliente    boolean not null default false,
  texto         text,
  foto          text,
  creado        timestamptz not null default now(),
  leido_equipo  boolean not null default false,
  leido_cliente boolean not null default false
);
create index if not exists mensajes_cliente_idx on public.mensajes(cliente_id, creado);
alter table public.mensajes enable row level security;
drop policy if exists equipo_mensajes on public.mensajes;
drop policy if exists cliente_ve      on public.mensajes;
drop policy if exists cliente_escribe on public.mensajes;
create policy equipo_mensajes on public.mensajes for all to authenticated
  using (atiende(cliente_id)) with check (atiende(cliente_id));
create policy cliente_ve on public.mensajes for select to authenticated
  using (cliente_id = mi_cliente_id());
create policy cliente_escribe on public.mensajes for insert to authenticated
  with check (cliente_id = mi_cliente_id() and de_cliente and autor_id = auth.uid());

-- 4) Recomendaciones: "te estás quedando sin…"
create table if not exists public.recomendaciones (
  id         uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  tipo       text not null check (tipo in ('p','k')),
  item_id    uuid not null,
  cantidad   int  not null default 1 check (cantidad > 0),
  nota       text,
  estado     text not null default 'activa' check (estado in ('activa','pedida','descartada')),
  autor_id   uuid default auth.uid(),
  creado     timestamptz not null default now()
);
create index if not exists recomendaciones_cliente_idx on public.recomendaciones(cliente_id, estado);
alter table public.recomendaciones enable row level security;
drop policy if exists equipo_recom on public.recomendaciones;
create policy equipo_recom on public.recomendaciones for all to authenticated
  using (atiende(cliente_id)) with check (atiende(cliente_id));

-- 5) Pedidos de la tienda
create table if not exists public.pedidos (
  id           uuid primary key default gen_random_uuid(),
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  items        jsonb not null,  -- [{t, id, nombre, precio, n}]
  total        numeric not null default 0,
  pago         text not null default 'cuenta' check (pago in ('cuenta','transferencia','efectivo')),
  nota         text,
  estado       text not null default 'nuevo' check (estado in ('nuevo','confirmado','entregado','cancelado')),
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now(),
  atendido_por uuid,
  venta_ids    uuid[]
);
create index if not exists pedidos_cliente_idx on public.pedidos(cliente_id, creado desc);
create index if not exists pedidos_estado_idx on public.pedidos(estado);
alter table public.pedidos enable row level security;
drop policy if exists equipo_ve_pedidos     on public.pedidos;
drop policy if exists equipo_edita_pedidos  on public.pedidos;
create policy equipo_ve_pedidos on public.pedidos for select to authenticated using (atiende(cliente_id));
create policy equipo_edita_pedidos on public.pedidos for update to authenticated using (atiende(cliente_id)) with check (atiende(cliente_id));

-- 6) Lo que usa el portal de clientes (siempre solo SU pileta)
create or replace function public.vincular_pileta(p_codigo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; dueno uuid;
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  if es_equipo() then raise exception 'Esta es una cuenta del equipo. Creá una cuenta de cliente aparte.'; end if;
  select id, usuario_id into cid, dueno from clientes where codigo = upper(trim(p_codigo));
  if cid is null then raise exception 'El código no es válido. Revisalo con tu piletero.'; end if;
  if dueno is not null and dueno <> auth.uid() then
    raise exception 'Ese código ya lo usa otra cuenta. Pedile uno nuevo a tu piletero.';
  end if;
  update clientes set usuario_id = auth.uid() where id = cid;
  return cid;
end $$;

create or replace function public.mi_pileta() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono,
                                 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia),
    'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color)
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
    'catalogo', coalesce((select json_agg(z order by z.t desc, z.nombre) from (
                   select 'p' as t, pr.id, pr.nombre, pr.detalle, pr.precio, (pr.stock > 0) as hay
                     from productos pr where pr.tienda and coalesce(pr.precio, 0) > 0
                   union all
                   select 'k', k.id, k.nombre,
                          (select string_agg(coalesce(pp.nombre, '?') || ' ×' || (i->>'n'), ', ')
                             from jsonb_array_elements(k.items) i left join productos pp on pp.id = (i->>'p')::uuid),
                          k.precio,
                          coalesce((select bool_and(coalesce(pp.stock, 0) >= (i->>'n')::numeric)
                                      from jsonb_array_elements(k.items) i left join productos pp on pp.id = (i->>'p')::uuid), false)
                     from kits k where k.tienda and coalesce(k.precio, 0) > 0) z), '[]'::json),
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
                    where cliente_id = c.id order by creado desc limit 20) q), '[]'::json)
  )
  from clientes c where c.usuario_id = auth.uid() order by c.creado limit 1;
$$;

create or replace function public.mi_fotos(p_limite int default 6) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select f.id, f.realizada_id, f.data, f.creado from fotos f
     where f.cliente_id = mi_cliente_id()
     order by f.creado desc limit least(coalesce(p_limite, 6), 100)) x;
$$;

create or replace function public.marcar_leidos_cliente() returns void
language sql security definer set search_path = public as $$
  update mensajes set leido_cliente = true
   where cliente_id = mi_cliente_id() and not de_cliente and not leido_cliente;
$$;

-- El cliente arma un pedido. Los precios salen de la base, no del celular.
create or replace function public.hacer_pedido(p_items jsonb, p_pago text default 'cuenta', p_nota text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid := mi_cliente_id(); it jsonb; v_t text; v_id uuid; v_n int; v_nom text; v_pre numeric;
        lista jsonb := '[]'::jsonb; tot numeric := 0; pid uuid;
begin
  if cid is null then raise exception 'Primero vinculá tu pileta con el código'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El carrito está vacío'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Demasiados productos en un pedido'; end if;
  if p_pago not in ('cuenta','transferencia','efectivo') then raise exception 'Forma de pago inválida'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    v_t := it->>'t'; v_id := (it->>'id')::uuid; v_n := (it->>'n')::int;
    if v_n is null or v_n < 1 or v_n > 50 then raise exception 'Cantidad inválida'; end if;
    if v_t = 'p' then select nombre, precio into v_nom, v_pre from productos where id = v_id and tienda;
    elsif v_t = 'k' then select nombre, precio into v_nom, v_pre from kits where id = v_id and tienda;
    else raise exception 'Producto inválido'; end if;
    if v_nom is null then raise exception 'Uno de los productos ya no está disponible'; end if;
    lista := lista || jsonb_build_object('t', v_t, 'id', v_id, 'nombre', v_nom, 'precio', v_pre, 'n', v_n);
    tot := tot + coalesce(v_pre, 0) * v_n;
  end loop;
  insert into pedidos (cliente_id, items, total, pago, nota) values (cid, lista, tot, p_pago, left(p_nota, 500)) returning id into pid;
  update recomendaciones r set estado = 'pedida'
   where r.cliente_id = cid and r.estado = 'activa'
     and exists (select 1 from jsonb_array_elements(lista) x where x->>'t' = r.tipo and (x->>'id')::uuid = r.item_id);
  return pid;
end $$;

create or replace function public.cancelar_mi_pedido(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update pedidos set estado = 'cancelado', actualizado = now()
   where id = p_id and cliente_id = mi_cliente_id() and estado = 'nuevo';
  if not found then raise exception 'Ese pedido ya no se puede cancelar. Escribile a tu piletero.'; end if;
end $$;

-- El equipo entrega un pedido: se registra como venta(s) al cliente y descuenta stock.
create or replace function public.entregar_pedido(p_id uuid, p_cobrado boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare pe pedidos; it jsonb; ids uuid[] := '{}'; vid uuid;
begin
  select * into pe from pedidos where id = p_id for update;
  if pe.id is null then raise exception 'El pedido no existe'; end if;
  if not atiende(pe.cliente_id) then raise exception 'Ese cliente no es tuyo'; end if;
  if pe.estado in ('entregado','cancelado') then raise exception 'El pedido ya está %', pe.estado; end if;
  for it in select value from jsonb_array_elements(pe.items) loop
    vid := vender(it->>'t', (it->>'id')::uuid, (it->>'n')::numeric, pe.cliente_id, coalesce(p_cobrado, false));
    ids := ids || vid;
  end loop;
  update pedidos set estado = 'entregado', venta_ids = ids, atendido_por = auth.uid(), actualizado = now() where id = p_id;
end $$;

revoke execute on function public.vincular_pileta(text), public.mi_pileta(), public.mi_fotos(int), public.marcar_leidos_cliente(),
  public.hacer_pedido(jsonb, text, text), public.cancelar_mi_pedido(uuid), public.entregar_pedido(uuid, boolean) from anon, public;
grant execute on function public.vincular_pileta(text), public.mi_pileta(), public.mi_fotos(int), public.marcar_leidos_cliente(),
  public.hacer_pedido(jsonb, text, text), public.cancelar_mi_pedido(uuid), public.entregar_pedido(uuid, boolean) to authenticated;

-- 7) SEGURIDAD: las cuentas de clientes nunca leen tablas internas.
--    Regla extra "solo el equipo" que se suma a las existentes (no las cambia).
do $$
declare t text;
begin
  foreach t in array array['clientes','herramientas','visitas','realizadas','ventas','productos','kits',
                           'pagos','movimientos','costos','ventas_costos','fotos','ubicaciones','recomendaciones','pedidos'] loop
    execute format('drop policy if exists solo_equipo on public.%I', t);
    execute format('create policy solo_equipo on public.%I as restrictive for all to public using (es_equipo()) with check (es_equipo())', t);
  end loop;
end $$;

-- perfiles: el equipo ve todo; cada uno ve/edita el suyo (necesario al dar de alta
-- un piletero nuevo); una cuenta de cliente no puede crearse perfil.
drop policy if exists solo_equipo_ver    on public.perfiles;
drop policy if exists solo_equipo_editar on public.perfiles;
drop policy if exists solo_equipo_borrar on public.perfiles;
drop policy if exists sin_clientes_alta  on public.perfiles;
create policy solo_equipo_ver    on public.perfiles as restrictive for select to public using (es_equipo() or id = auth.uid());
create policy solo_equipo_editar on public.perfiles as restrictive for update to public using (es_equipo() or id = auth.uid());
create policy solo_equipo_borrar on public.perfiles as restrictive for delete to public using (es_equipo());
create policy sin_clientes_alta  on public.perfiles as restrictive for insert to public
  with check (auth.uid() is not null and coalesce(auth.jwt() -> 'user_metadata' ->> 'tipo', '') <> 'cliente');
