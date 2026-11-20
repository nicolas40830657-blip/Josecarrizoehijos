-- Datos para cobrar de cada piletero (los ven sus clientes en la app)
alter table public.perfiles add column if not exists pago_alias   text;
alter table public.perfiles add column if not exists pago_cbu     text;
alter table public.perfiles add column if not exists pago_titular text;
alter table public.perfiles add column if not exists pago_banco   text;

-- mi_pileta: el piletero ahora incluye sus datos para transferir
create or replace function public.mi_pileta() returns json
language sql stable security definer set search_path = public as $$
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
