-- Pedidos en Inventario: los de la app de clientes y los que cargan los pileteros, con la coordinación de la entrega.
alter table public.pedidos add column if not exists origen text not null default 'app' check (origen in ('app', 'equipo'));
alter table public.pedidos add column if not exists creado_por uuid references public.perfiles(id) on delete set null;
alter table public.pedidos add column if not exists entrega date;
alter table public.pedidos add column if not exists lleva_id uuid references public.perfiles(id) on delete set null;
alter table public.pedidos add column if not exists coordinacion text check (coordinacion is null or length(coordinacion) <= 1000);

-- Quien lo lleva también lo ve
drop policy if exists lleva_ve_pedidos on public.pedidos;
create policy lleva_ve_pedidos on public.pedidos for select to authenticated using (lleva_id = auth.uid());

-- Un piletero (o coordinador) carga un pedido para un cliente
create or replace function public.pedido_equipo(p_cliente uuid, p_items jsonb, p_pago text default 'cuenta', p_nota text default null,
  p_entrega date default null, p_lleva uuid default null, p_coord text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; v_t text; v_id uuid; v_n int; v_nom text; v_pre numeric; v_promo boolean; v_regalo text;
        v_pc int; v_pd numeric; v_tot numeric; lista jsonb := '[]'::jsonb; tot numeric := 0; pid uuid; extra jsonb;
begin
  if not atiende(p_cliente) then raise exception 'Ese cliente no es tuyo'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Agregá al menos un producto'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Demasiados productos en un pedido'; end if;
  if p_pago not in ('cuenta','transferencia','efectivo') then raise exception 'Forma de pago inválida'; end if;
  if p_lleva is not null and not exists (select 1 from perfiles where id = p_lleva and activo) then raise exception 'Ese piletero no está habilitado'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    v_t := it->>'t'; v_id := (it->>'id')::uuid; v_n := (it->>'n')::int; v_nom := null; v_pc := null; v_pd := null;
    if v_n is null or v_n < 1 or v_n > 200 then raise exception 'Cantidad inválida'; end if;
    if v_t = 'p' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end, pack_cant, pack_desc
        into v_nom, v_pre, v_promo, v_regalo, v_pc, v_pd from productos where id = v_id;
    elsif v_t = 'k' then
      select nombre, case when promo_vigente(promo, promo_hasta) and promo_precio is not null then promo_precio else precio end,
             promo_vigente(promo, promo_hasta), case when promo_vigente(promo, promo_hasta) then promo_regalo end
        into v_nom, v_pre, v_promo, v_regalo from kits where id = v_id;
    else raise exception 'Producto inválido'; end if;
    if v_nom is null then raise exception 'Uno de los productos ya no existe'; end if;
    v_tot := total_linea(coalesce(v_pre, 0), v_n, v_pc, v_pd);
    extra := jsonb_build_object('total', v_tot);
    if v_promo then extra := extra || jsonb_build_object('promo', true, 'regalo', v_regalo); end if;
    if v_pc is not null and v_n >= v_pc then extra := extra || jsonb_build_object('pack', 'pack x' || v_pc || ' −' || trim(to_char(v_pd, 'FM990.##')) || '%'); end if;
    lista := lista || jsonb_build_array(jsonb_build_object('t', v_t, 'id', v_id, 'nombre', v_nom, 'precio', v_pre, 'n', v_n) || extra);
    tot := tot + v_tot;
  end loop;
  insert into pedidos (cliente_id, items, total, pago, nota, origen, creado_por, entrega, lleva_id, coordinacion)
  values (p_cliente, lista, tot, p_pago, left(p_nota, 500), 'equipo', auth.uid(), p_entrega, p_lleva, left(p_coord, 1000)) returning id into pid;
  return pid;
end $$;

-- Coordinar la entrega: cuándo, quién lo lleva, cómo paga y qué se habló
create or replace function public.coordinar_pedido(p_id uuid, p_entrega date, p_lleva uuid, p_pago text, p_coord text)
returns void language plpgsql security definer set search_path = public as $$
declare pe pedidos; c clientes; yo text;
begin
  select * into pe from pedidos where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if not (atiende(pe.cliente_id) or pe.lleva_id = auth.uid()) then raise exception 'No podés coordinar este pedido'; end if;
  if pe.estado in ('entregado', 'cancelado') then raise exception 'El pedido ya está %', pe.estado; end if;
  if p_pago not in ('cuenta','transferencia','efectivo') then raise exception 'Forma de pago inválida'; end if;
  if p_lleva is not null and not exists (select 1 from perfiles where id = p_lleva and activo) then raise exception 'Ese piletero no está habilitado'; end if;
  update pedidos set entrega = p_entrega, lleva_id = p_lleva, pago = p_pago, coordinacion = nullif(left(trim(coalesce(p_coord, '')), 1000), ''),
         atendido_por = auth.uid(), actualizado = now() where id = p_id;
  if p_lleva is not null and p_lleva is distinct from pe.lleva_id and p_lleva <> auth.uid() then
    select * into c from clientes where id = pe.cliente_id;
    select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
    perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', p_lleva, 'title', '🧾 ' || coalesce(yo, 'El equipo') || ' te pasó un pedido para llevar',
      'body', c.nombre || coalesce(' · ' || to_char(p_entrega, 'DD/MM'), '') || ' · $' || to_char(pe.total, 'FM999G999G999'), 'url', 'index.html#pedido=' || p_id, 'tag', 'pedido-' || p_id));
  end if;
end $$;

-- Entregar: también lo puede registrar quien lo lleva
create or replace function public.entregar_pedido(p_id uuid, p_cobrado boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare pe pedidos; it jsonb; ids uuid[] := '{}'; vid uuid; nota text;
begin
  select * into pe from pedidos where id = p_id for update;
  if pe.id is null then raise exception 'El pedido no existe'; end if;
  if not (atiende(pe.cliente_id) or pe.lleva_id = auth.uid()) then raise exception 'Ese cliente no es tuyo'; end if;
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

-- vender: el piletero que lleva un pedido abierto de ese cliente también puede registrarle la venta
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
     and not exists (select 1 from clientes where id = p_cliente and piletero_id = auth.uid())
     and not exists (select 1 from pedidos where cliente_id = p_cliente and lleva_id = auth.uid() and estado in ('nuevo', 'confirmado')) then
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

revoke execute on function public.pedido_equipo(uuid, jsonb, text, text, date, uuid, text), public.coordinar_pedido(uuid, date, uuid, text, text) from public, anon;
grant execute on function public.pedido_equipo(uuid, jsonb, text, text, date, uuid, text), public.coordinar_pedido(uuid, date, uuid, text, text) to authenticated;
