-- Packs con descuento por cantidad en productos sueltos (ej: llevando 3, 10% OFF en esas 3)
-- y ganancia visible en la app de gestión (se calcula en la app con costo y precio).
alter table public.productos add column if not exists pack_cant int check (pack_cant is null or pack_cant between 2 and 50);
alter table public.productos add column if not exists pack_desc numeric not null default 10 check (pack_desc > 0 and pack_desc < 100);

-- Total de una línea: cada pack completo con descuento, lo que sobra a precio normal. Redondeado al peso.
create or replace function public.total_linea(p_precio numeric, p_n numeric, p_cant int, p_desc numeric)
returns numeric language sql immutable set search_path = public as $$
  select case when p_cant is null or p_cant < 2 or p_n < p_cant then round(p_precio * p_n)
              else round(floor(p_n / p_cant) * p_cant * p_precio * (1 - coalesce(p_desc, 10) / 100) + mod(p_n, p_cant) * p_precio) end;
$$;

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
    'catalogo', coalesce((select json_agg(z order by z.promo desc, (z.pack_cant is not null) desc, z.t desc, z.nombre) from (
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


-- Pedido del cliente: aplica promo y pack, y guarda el total de cada línea
create or replace function public.hacer_pedido(p_items jsonb, p_pago text default 'cuenta', p_nota text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid := mi_cliente_id(); it jsonb; v_t text; v_id uuid; v_n int; v_nom text; v_pre numeric; v_promo boolean; v_regalo text;
        v_pc int; v_pd numeric; v_tot numeric; lista jsonb := '[]'::jsonb; tot numeric := 0; pid uuid; extra jsonb;
begin
  if cid is null then raise exception 'Primero vinculá tu pileta con el código'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El carrito está vacío'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Demasiados productos en un pedido'; end if;
  if p_pago not in ('cuenta','transferencia','efectivo') then raise exception 'Forma de pago inválida'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    v_t := it->>'t'; v_id := (it->>'id')::uuid; v_n := (it->>'n')::int; v_nom := null; v_pc := null; v_pd := null;
    if v_n is null or v_n < 1 or v_n > 50 then raise exception 'Cantidad inválida'; end if;
    if v_t = 'p' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end, pack_cant, pack_desc
        into v_nom, v_pre, v_promo, v_regalo, v_pc, v_pd from productos where id = v_id and tienda;
    elsif v_t = 'k' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end
        into v_nom, v_pre, v_promo, v_regalo from kits where id = v_id and tienda;
    else raise exception 'Producto inválido'; end if;
    if v_nom is null then raise exception 'Uno de los productos ya no está disponible'; end if;
    v_tot := total_linea(coalesce(v_pre, 0), v_n, v_pc, v_pd);
    extra := jsonb_build_object('total', v_tot);
    if v_promo then extra := extra || jsonb_build_object('promo', true, 'regalo', v_regalo); end if;
    if v_pc is not null and v_n >= v_pc then extra := extra || jsonb_build_object('pack', 'pack x' || v_pc || ' −' || trim(to_char(v_pd, 'FM990.##')) || '%'); end if;
    lista := lista || jsonb_build_array(jsonb_build_object('t', v_t, 'id', v_id, 'nombre', v_nom, 'precio', v_pre, 'n', v_n) || extra);
    tot := tot + v_tot;
  end loop;
  insert into pedidos (cliente_id, items, total, pago, nota) values (cid, lista, tot, p_pago, left(p_nota, 500)) returning id into pid;
  update recomendaciones r set estado = 'pedida'
   where r.cliente_id = cid and r.estado = 'activa'
     and exists (select 1 from jsonb_array_elements(lista) x where x->>'t' = r.tipo and (x->>'id')::uuid = r.item_id);
  return pid;
end $$;

-- Entrega: la venta queda con el total de la línea del pedido (promo y pack incluidos)
create or replace function public.entregar_pedido(p_id uuid, p_cobrado boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare pe pedidos; it jsonb; ids uuid[] := '{}'; vid uuid; nota text;
begin
  select * into pe from pedidos where id = p_id for update;
  if pe.id is null then raise exception 'El pedido no existe'; end if;
  if not atiende(pe.cliente_id) then raise exception 'Ese cliente no es tuyo'; end if;
  if pe.estado in ('entregado','cancelado') then raise exception 'El pedido ya está %', pe.estado; end if;
  for it in select value from jsonb_array_elements(pe.items) loop
    vid := vender(it->>'t', (it->>'id')::uuid, (it->>'n')::numeric, pe.cliente_id, coalesce(p_cobrado, false));
    if it ? 'precio' then
      nota := concat_ws(' · ', case when (it->>'promo')::boolean then 'promo' end, nullif(it->>'regalo', ''), it->>'pack');
      update ventas set total = coalesce((it->>'total')::numeric, (it->>'precio')::numeric * (it->>'n')::numeric),
                        nombre = regexp_replace(nombre, ' \(pack x[^)]*\)$', '') || case when nota <> '' then ' (' || nota || ')' else '' end
       where id = vid;
    end if;
    ids := ids || vid;
  end loop;
  update pedidos set estado = 'entregado', venta_ids = ids, atendido_por = auth.uid(), actualizado = now() where id = p_id;
end $$;

-- Venta en persona desde la app de gestión: también aplica el pack
create or replace function public.vender(p_tipo text, p_item uuid, p_cant numeric, p_cliente uuid default null, p_cobrado boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_items jsonb; v_nombre text; v_precio numeric; v_porc numeric; v_id uuid; v_pc int; v_pd numeric; v_total numeric;
  it jsonb; v_pid uuid; v_n numeric; v_stock numeric; v_pn text; v_c numeric; v_costo numeric := 0;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  if p_cant is null or p_cant < 1 or p_cant <> floor(p_cant) then raise exception 'Cantidad inválida'; end if;
  if p_tipo = 'p' then
    select nombre, precio, pack_cant, pack_desc into v_nombre, v_precio, v_pc, v_pd from productos where id = p_item;
    if v_nombre is null then raise exception 'El producto no existe'; end if;
    v_items := jsonb_build_array(jsonb_build_object('p', p_item, 'n', 1));
  elsif p_tipo = 'k' then
    select nombre, precio, items into v_nombre, v_precio, v_items from kits where id = p_item;
    if v_nombre is null then raise exception 'El kit no existe'; end if;
  else
    raise exception 'Tipo de venta inválido';
  end if;
  if p_cliente is not null and not es_gestor()
     and not exists (select 1 from clientes where id = p_cliente and piletero_id = auth.uid()) then
    raise exception 'Ese cliente no es tuyo';
  end if;
  v_total := total_linea(coalesce(v_precio, 0), p_cant, v_pc, v_pd);
  if v_pc is not null and p_cant >= v_pc then v_nombre := v_nombre || ' (pack x' || v_pc || ' −' || trim(to_char(v_pd, 'FM990.##')) || '%)'; end if;
  select coalesce(porc_productos, 0) into v_porc from perfiles where id = auth.uid();
  insert into ventas (fecha, tipo, item_id, nombre, cantidad, total, porc, vendedor_id, cliente_id, items, cobrado, cobrado_fecha)
  values (hoy, p_tipo, p_item, v_nombre, p_cant, v_total, coalesce(v_porc, 0), auth.uid(), p_cliente, v_items,
          coalesce(p_cobrado, true), case when coalesce(p_cobrado, true) then hoy end)
  returning id into v_id;
  for it in select value from jsonb_array_elements(v_items) loop
    v_pid := (it->>'p')::uuid; v_n := (it->>'n')::numeric * p_cant;
    select stock, nombre into v_stock, v_pn from productos where id = v_pid for update;
    if v_stock is null then raise exception 'Falta un producto del kit'; end if;
    if v_stock < v_n then raise exception 'No hay stock suficiente de %', v_pn; end if;
    update productos set stock = stock - v_n where id = v_pid;
    insert into movimientos (producto_id, nombre, tipo, cantidad, stock_resultante, usuario_id, venta_id)
    values (v_pid, v_pn, 'venta', -v_n, v_stock - v_n, auth.uid(), v_id);
    select costo into v_c from costos where producto_id = v_pid;
    v_costo := v_costo + coalesce(v_c, 0) * v_n;
  end loop;
  insert into ventas_costos (venta_id, costo) values (v_id, v_costo);
  return v_id;
end $$;
