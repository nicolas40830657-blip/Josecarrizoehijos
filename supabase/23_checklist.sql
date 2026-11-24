-- Checklist del mantenimiento: el piletero confirma qué hizo y el cliente lo ve en su app
alter table public.realizadas add column if not exists tareas text[];
alter table public.realizadas drop constraint if exists realizadas_tareas_validas;
alter table public.realizadas add constraint realizadas_tareas_validas check (tareas is null or tareas <@ array['superficie', 'fondo', 'productos', 'retrolavado']::text[]);

create or replace function public.mi_pileta()
returns json language sql stable security definer set search_path = public as $$
 select json_build_object(
  'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono, 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia, 'ref', c.ref,
                               'tipo', c.tipo, 'abono', c.abono, 'visitas_semana', c.visitas_semana),
  'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color, 'alias', p.pago_alias, 'cbu', p.pago_cbu, 'titular', p.pago_titular, 'banco', p.pago_banco) from perfiles p where p.id = c.piletero_id),
  'visitas', coalesce((select json_agg(json_build_object('fecha', v.fecha, 'hora', v.hora, 'repetir', v.repetir, 'omitir', v.omitir)) from visitas v where v.cliente_id = c.id), '[]'::json),
  'realizadas', coalesce((select json_agg(x) from ( select r.id, r.fecha, r.valor, r.nota, r.productos, r.tareas, p.nombre as piletero from realizadas r left join perfiles p on p.id = r.piletero_id where r.cliente_id = c.id order by r.fecha desc limit 60) x), '[]'::json),
  'ventas', coalesce((select json_agg(y) from ( select s.id, s.fecha, s.nombre, s.cantidad, s.total, s.cobrado from ventas s where s.cliente_id = c.id and not coalesce(s.anulada, false) order by s.fecha desc, s.creado desc limit 40) y), '[]'::json),
  'catalogo', catalogo(),
  'recomendaciones', coalesce((select json_agg(w) from ( select r.id, r.tipo as t, r.item_id as id_item, r.cantidad, r.nota, r.creado, coalesce(pr.nombre, k.nombre) as nombre, coalesce(pr.precio, k.precio) as precio from recomendaciones r left join productos pr on r.tipo = 'p' and pr.id = r.item_id left join kits k on r.tipo = 'k' and k.id = r.item_id where r.cliente_id = c.id and r.estado = 'activa' and coalesce(pr.id, k.id) is not null order by r.creado desc) w), '[]'::json),
  'pedidos', coalesce((select json_agg(q) from ( select id, items, total, pago, nota, estado, creado from pedidos where cliente_id = c.id order by creado desc limit 20) q), '[]'::json),
  'premios', coalesce((select json_agg(pm) from ( select pz.id, pz.texto, pz.estado, pz.creado, split_part(rc.nombre, ' ', 1) as referido from premios pz join clientes rc on rc.id = pz.referido_id where pz.cliente_id = c.id order by pz.creado desc limit 20) pm), '[]'::json),
  'premio_recomendar', (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar'))
 from clientes c where c.id = mi_cliente_id();
$$;
