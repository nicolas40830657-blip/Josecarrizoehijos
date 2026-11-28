-- 28: Administraciones pagan el abono a la empresa; coordinador del edificio entra con el código
--     del edificio y no ve plata ni tienda; panel de administración con productos y semana.

alter table clientes add column if not exists contacto_tel text;

-- ¿El usuario actual entra a un edificio de una administración sin ser esa administración? (coordinador del edificio)
create or replace function public.es_sin_plata(cid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from clientes c where c.id = cid and c.administracion_id is not null
                 and c.administracion_id is distinct from mi_administracion_id());
$$;

create or replace function public.mi_pileta() returns json
language sql stable security definer set search_path to 'public' as $function$
 with c as (select cl.*, es_sin_plata(cl.id) as sp from clientes cl where cl.id = mi_cliente_id())
 select json_build_object(
  'sin_plata', c.sp,
  'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono,
                               'valor_visita', case when c.sp then null else c.valor_visita end, 'frecuencia', c.frecuencia, 'dia', c.dia, 'ref', c.ref,
                               'tipo', c.tipo, 'abono', case when c.sp then null else c.abono end, 'visitas_semana', c.visitas_semana, 'contacto', c.contacto,
                               'administracion', (select a.nombre from administraciones a where a.id = c.administracion_id)),
  'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color,
               'alias', case when c.sp or c.administracion_id is not null then null else p.pago_alias end,
               'cbu', case when c.sp or c.administracion_id is not null then null else p.pago_cbu end,
               'titular', case when c.sp or c.administracion_id is not null then null else p.pago_titular end,
               'banco', case when c.sp or c.administracion_id is not null then null else p.pago_banco end) from perfiles p where p.id = c.piletero_id),
  'visitas', coalesce((select json_agg(json_build_object('fecha', v.fecha, 'hora', v.hora, 'repetir', v.repetir, 'omitir', v.omitir)) from visitas v where v.cliente_id = c.id), '[]'::json),
  'realizadas', coalesce((select json_agg(x) from ( select r.id, r.fecha, case when c.sp then null else r.valor end as valor, r.nota, r.productos, r.tareas, p.nombre as piletero from realizadas r left join perfiles p on p.id = r.piletero_id where r.cliente_id = c.id order by r.fecha desc limit 60) x), '[]'::json),
  'ventas', case when c.sp then '[]'::json else coalesce((select json_agg(y) from ( select s.id, s.fecha, s.nombre, s.cantidad, s.total, s.cobrado from ventas s where s.cliente_id = c.id and not coalesce(s.anulada, false) order by s.fecha desc, s.creado desc limit 40) y), '[]'::json) end,
  'abono_cobros', case when c.sp then '[]'::json else coalesce((select json_agg(ab order by ab.mes desc) from (select a.mes, a.monto, a.fecha from abono_cobros a where a.cliente_id = c.id order by a.mes desc limit 12) ab), '[]'::json) end,
  'catalogo', case when c.sp then '[]'::json else catalogo() end,
  'recomendaciones', case when c.sp then '[]'::json else coalesce((select json_agg(w) from ( select r.id, r.tipo as t, r.item_id as id_item, r.cantidad, r.nota, r.creado, coalesce(pr.nombre, k.nombre) as nombre, coalesce(pr.precio, k.precio) as precio from recomendaciones r left join productos pr on r.tipo = 'p' and pr.id = r.item_id left join kits k on r.tipo = 'k' and k.id = r.item_id where r.cliente_id = c.id and r.estado = 'activa' and coalesce(pr.id, k.id) is not null order by r.creado desc) w), '[]'::json) end,
  'pedidos', case when c.sp then '[]'::json else coalesce((select json_agg(q) from ( select id, items, total, pago, nota, estado, creado from pedidos where cliente_id = c.id order by creado desc limit 20) q), '[]'::json) end,
  'premios', case when c.sp then '[]'::json else coalesce((select json_agg(pm) from ( select pz.id, pz.texto, pz.estado, pz.creado, split_part(rc.nombre, ' ', 1) as referido from premios pz join clientes rc on rc.id = pz.referido_id where pz.cliente_id = c.id order by pz.creado desc limit 20) pm), '[]'::json) end,
  'premio_recomendar', case when c.sp then null else (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar') end)
 from c;
$function$;

-- El coordinador del edificio no hace pedidos (los productos los pide la administración)
do $$ declare f text := pg_get_functiondef('hacer_pedido(jsonb,text,text)'::regprocedure); begin
  if position('es_sin_plata' in f) = 0 then
    f := replace(f, 'if cid is null then raise exception ''Primero vinculá tu pileta con el código''; end if;',
      'if cid is null then raise exception ''Primero vinculá tu pileta con el código''; end if;' || chr(10) ||
      '  if es_sin_plata(cid) then raise exception ''Los productos de este edificio los pide la administración''; end if;');
    execute f;
  end if;
end $$;

-- Panel de la administración: edificios con coordinador y semana, abono + productos del mes, pagos a la empresa
create or replace function public.mi_administracion() returns json
language plpgsql stable security definer set search_path to 'public' as $function$
declare a administraciones; hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
        v_mes text := to_char(hoy, 'YYYY-MM'); lun date := hoy - ((extract(isodow from hoy)::int) - 1); pago jsonb;
begin
  select * into a from administraciones where id = mi_administracion_id();
  if a.id is null then return null; end if;
  select valor into pago from ajustes where clave = 'pago_empresa';
  return json_build_object(
    'id', a.id, 'nombre', a.nombre, 'sel', mi_cliente_id(), 'mes', v_mes,
    'edificios', coalesce((select json_agg(x order by x.nombre) from (
       select c.id, c.nombre, c.direccion, c.abono, c.visitas_semana, c.contacto, c.contacto_tel, p.nombre as piletero,
              (select max(r.fecha) from realizadas r where r.cliente_id = c.id) as ultima,
              (select count(*) from realizadas r where r.cliente_id = c.id and to_char(r.fecha, 'YYYY-MM') = v_mes) as visitas_mes,
              (select count(distinct r.fecha) from realizadas r where r.cliente_id = c.id and r.fecha between lun and lun + 6) as semana
         from clientes c left join perfiles p on p.id = c.piletero_id where c.administracion_id = a.id) x), '[]'::json),
    'total', (select coalesce(sum(c2.abono), 0) from clientes c2 where c2.administracion_id = a.id),
    'productos', coalesce((select json_agg(z order by z.fecha desc) from (
       select s.fecha, s.nombre, s.cantidad, s.total, s.cobrado, c3.nombre as edificio
         from ventas s join clientes c3 on c3.id = s.cliente_id
        where c3.administracion_id = a.id and not coalesce(s.anulada, false) and to_char(s.fecha, 'YYYY-MM') = v_mes) z), '[]'::json),
    'pagos', coalesce((select json_agg(y order by y.mes desc) from (select ap.mes, ap.monto, ap.pagado, ap.fecha from abono_pagos ap where ap.administracion_id = a.id order by ap.mes desc limit 12) y), '[]'::json),
    'pago_empresa', pago);
end $function$;
