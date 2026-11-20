-- Promociones de kits y productos (se configuran en la app de gestión; el cliente las ve en su app)
alter table public.productos add column if not exists promo boolean not null default false;
alter table public.productos add column if not exists promo_precio numeric check (promo_precio is null or promo_precio > 0);
alter table public.productos add column if not exists promo_regalo text;
alter table public.productos add column if not exists promo_texto text;
alter table public.productos add column if not exists promo_hasta date;
alter table public.kits add column if not exists promo boolean not null default false;
alter table public.kits add column if not exists promo_precio numeric check (promo_precio is null or promo_precio > 0);
alter table public.kits add column if not exists promo_regalo text;
alter table public.kits add column if not exists promo_texto text;
alter table public.kits add column if not exists promo_hasta date;

-- ¿Está vigente? (se apaga sola cuando pasa la fecha "hasta")
create or replace function public.promo_vigente(p_promo boolean, p_hasta date)
returns boolean language sql stable set search_path = public as $$
  select coalesce(p_promo, false) and (p_hasta is null or p_hasta >= (now() at time zone 'America/Argentina/Buenos_Aires')::date);
$$;

-- Catálogo del cliente: precio final (con promo si hay) + datos de la promo
create or replace function public.mi_pileta()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono,
                                 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia),
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
    'catalogo', coalesce((select json_agg(z order by z.promo desc, z.t desc, z.nombre) from (
                   select 'p' as t, pr.id, pr.nombre, pr.detalle,
                          case when promo_vigente(pr.promo, pr.promo_hasta) and pr.promo_precio is not null then pr.promo_precio else pr.precio end as precio,
                          pr.precio as precio_lista, promo_vigente(pr.promo, pr.promo_hasta) as promo,
                          case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_regalo end as regalo,
                          case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_texto end as promo_texto,
                          case when promo_vigente(pr.promo, pr.promo_hasta) then pr.promo_hasta end as promo_hasta,
                          (pr.stock > 0) as hay
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

-- El pedido toma el precio de promo vigente y anota el regalo
create or replace function public.hacer_pedido(p_items jsonb, p_pago text default 'cuenta', p_nota text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid := mi_cliente_id(); it jsonb; v_t text; v_id uuid; v_n int; v_nom text; v_pre numeric; v_promo boolean; v_regalo text;
        lista jsonb := '[]'::jsonb; tot numeric := 0; pid uuid;
begin
  if cid is null then raise exception 'Primero vinculá tu pileta con el código'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El carrito está vacío'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Demasiados productos en un pedido'; end if;
  if p_pago not in ('cuenta','transferencia','efectivo') then raise exception 'Forma de pago inválida'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    v_t := it->>'t'; v_id := (it->>'id')::uuid; v_n := (it->>'n')::int; v_nom := null;
    if v_n is null or v_n < 1 or v_n > 50 then raise exception 'Cantidad inválida'; end if;
    if v_t = 'p' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end
        into v_nom, v_pre, v_promo, v_regalo from productos where id = v_id and tienda;
    elsif v_t = 'k' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end
        into v_nom, v_pre, v_promo, v_regalo from kits where id = v_id and tienda;
    else raise exception 'Producto inválido'; end if;
    if v_nom is null then raise exception 'Uno de los productos ya no está disponible'; end if;
    lista := lista || jsonb_build_array(jsonb_build_object('t', v_t, 'id', v_id, 'nombre', v_nom, 'precio', v_pre, 'n', v_n)
                   || case when v_promo then jsonb_build_object('promo', true, 'regalo', v_regalo) else '{}'::jsonb end);
    tot := tot + coalesce(v_pre, 0) * v_n;
  end loop;
  insert into pedidos (cliente_id, items, total, pago, nota) values (cid, lista, tot, p_pago, left(p_nota, 500)) returning id into pid;
  update recomendaciones r set estado = 'pedida'
   where r.cliente_id = cid and r.estado = 'activa'
     and exists (select 1 from jsonb_array_elements(lista) x where x->>'t' = r.tipo and (x->>'id')::uuid = r.item_id);
  return pid;
end $$;

-- Al entregar, la venta queda al precio que aceptó el cliente en el pedido (incluida la promo)
create or replace function public.entregar_pedido(p_id uuid, p_cobrado boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare pe pedidos; it jsonb; ids uuid[] := '{}'; vid uuid;
begin
  select * into pe from pedidos where id = p_id for update;
  if pe.id is null then raise exception 'El pedido no existe'; end if;
  if not atiende(pe.cliente_id) then raise exception 'Ese cliente no es tuyo'; end if;
  if pe.estado in ('entregado','cancelado') then raise exception 'El pedido ya está %', pe.estado; end if;
  for it in select value from jsonb_array_elements(pe.items) loop
    vid := vender(it->>'t', (it->>'id')::uuid, (it->>'n')::numeric, pe.cliente_id, coalesce(p_cobrado, false));
    if it ? 'precio' then
      update ventas set total = (it->>'precio')::numeric * (it->>'n')::numeric,
                        nombre = nombre || case when (it->>'promo')::boolean then ' (promo' || coalesce(' · ' || nullif(it->>'regalo', ''), '') || ')' else '' end
       where id = vid;
    end if;
    ids := ids || vid;
  end loop;
  update pedidos set estado = 'entregado', venta_ids = ids, atendido_por = auth.uid(), actualizado = now() where id = p_id;
end $$;
