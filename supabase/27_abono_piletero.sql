-- Edificios: cada uno tiene su administrador (la persona) que usa la app de su pileta con el link del edificio.
-- El abono mensual lo cobra el piletero: lo registra él, se queda el 70% y el 30% va a la empresa en "Pagar todo".
alter table public.clientes add column if not exists contacto text check (contacto is null or length(contacto) <= 120);

create table if not exists public.abono_cobros (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  monto numeric not null check (monto >= 0),
  piletero_id uuid default auth.uid() references public.perfiles(id) on delete set null,
  pago_id uuid references public.pagos(id) on delete set null,
  fecha date not null default (now() at time zone 'America/Argentina/Buenos_Aires')::date,
  creado timestamptz not null default now(),
  unique (cliente_id, mes)
);
alter table public.abono_cobros enable row level security;
drop policy if exists solo_equipo on public.abono_cobros;
create policy solo_equipo on public.abono_cobros as restrictive for all to authenticated using (es_equipo()) with check (es_equipo());
drop policy if exists cobros on public.abono_cobros;
create policy cobros on public.abono_cobros for all to authenticated
  using (es_gestor() or piletero_id = auth.uid() or atiende(cliente_id))
  with check (es_gestor() or (piletero_id = auth.uid() and atiende(cliente_id) and pago_id is null));
revoke all on public.abono_cobros from anon;
grant select, insert, update, delete on public.abono_cobros to authenticated;

-- Las visitas de un edificio con abono no suman plata por visita (la plata es el abono del mes)
create or replace function public.marcar_abono_realizada()
returns trigger language plpgsql security definer set search_path = public as $$
declare c clientes;
begin
  select * into c from clientes where id = new.cliente_id;
  if c.tipo = 'institucion' and coalesce(c.abono, 0) > 0 then new.abono := true; new.valor := 0;
  else new.abono := false; end if;
  return new;
end $$;

-- Pagar todo: 30% de mantenimientos + productos sin rendir + 30% de los abonos cobrados
alter table public.pagos add column if not exists abonos numeric not null default 0;
alter table public.pagos add column if not exists abonos_n int not null default 0;
create or replace function public.pagar(empresa numeric default 0.3)
returns void language plpgsql security definer set search_path = public as $$
declare v_m numeric; v_n int; v_p numeric; v_nv int; v_a numeric; v_na int; v_id uuid;
begin
  if not es_equipo() then raise exception 'No autorizado'; end if;
  select coalesce(sum(valor), 0) * 0.3, count(*) into v_m, v_n
    from realizadas where piletero_id = auth.uid() and pago_id is null and not abono;
  select round(coalesce(sum(total - total * coalesce(porc, 0) / 100), 0)), count(*) into v_p, v_nv
    from ventas where vendedor_id = auth.uid() and pago_id is null and not coalesce(anulada, false);
  select round(coalesce(sum(monto), 0) * 0.3), count(*) into v_a, v_na
    from abono_cobros where piletero_id = auth.uid() and pago_id is null;
  if v_n = 0 and v_nv = 0 and v_na = 0 then return; end if;
  insert into pagos (piletero_id, monto, visitas, productos, ventas, abonos, abonos_n)
  values (auth.uid(), v_m + v_p + v_a, v_n, v_p, v_nv, v_a, v_na) returning id into v_id;
  update realizadas set pago_id = v_id where piletero_id = auth.uid() and pago_id is null and not abono;
  update ventas set pago_id = v_id where vendedor_id = auth.uid() and pago_id is null and not coalesce(anulada, false);
  update abono_cobros set pago_id = v_id where piletero_id = auth.uid() and pago_id is null;
end $$;

-- La app del edificio ve si el abono de cada mes ya está pagado
create or replace function public.mi_pileta()
returns json language sql stable security definer set search_path = public as $$
 select json_build_object(
  'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono, 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia, 'ref', c.ref,
                               'tipo', c.tipo, 'abono', c.abono, 'visitas_semana', c.visitas_semana, 'contacto', c.contacto),
  'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color, 'alias', p.pago_alias, 'cbu', p.pago_cbu, 'titular', p.pago_titular, 'banco', p.pago_banco) from perfiles p where p.id = c.piletero_id),
  'visitas', coalesce((select json_agg(json_build_object('fecha', v.fecha, 'hora', v.hora, 'repetir', v.repetir, 'omitir', v.omitir)) from visitas v where v.cliente_id = c.id), '[]'::json),
  'realizadas', coalesce((select json_agg(x) from ( select r.id, r.fecha, r.valor, r.nota, r.productos, r.tareas, p.nombre as piletero from realizadas r left join perfiles p on p.id = r.piletero_id where r.cliente_id = c.id order by r.fecha desc limit 60) x), '[]'::json),
  'ventas', coalesce((select json_agg(y) from ( select s.id, s.fecha, s.nombre, s.cantidad, s.total, s.cobrado from ventas s where s.cliente_id = c.id and not coalesce(s.anulada, false) order by s.fecha desc, s.creado desc limit 40) y), '[]'::json),
  'abono_cobros', coalesce((select json_agg(ab order by ab.mes desc) from (select a.mes, a.monto, a.fecha from abono_cobros a where a.cliente_id = c.id order by a.mes desc limit 12) ab), '[]'::json),
  'catalogo', catalogo(),
  'recomendaciones', coalesce((select json_agg(w) from ( select r.id, r.tipo as t, r.item_id as id_item, r.cantidad, r.nota, r.creado, coalesce(pr.nombre, k.nombre) as nombre, coalesce(pr.precio, k.precio) as precio from recomendaciones r left join productos pr on r.tipo = 'p' and pr.id = r.item_id left join kits k on r.tipo = 'k' and k.id = r.item_id where r.cliente_id = c.id and r.estado = 'activa' and coalesce(pr.id, k.id) is not null order by r.creado desc) w), '[]'::json),
  'pedidos', coalesce((select json_agg(q) from ( select id, items, total, pago, nota, estado, creado from pedidos where cliente_id = c.id order by creado desc limit 20) q), '[]'::json),
  'premios', coalesce((select json_agg(pm) from ( select pz.id, pz.texto, pz.estado, pz.creado, split_part(rc.nombre, ' ', 1) as referido from premios pz join clientes rc on rc.id = pz.referido_id where pz.cliente_id = c.id order by pz.creado desc limit 20) pm), '[]'::json),
  'premio_recomendar', (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar'))
 from clientes c where c.id = mi_cliente_id();
$$;

-- mi_administracion: estado de cada edificio según abono_cobros (aplicado como migración "mi_administracion_abono_cobros")
-- edificios[].cobro = {monto, fecha} del mes; pagos = abono_cobros agrupados por mes (n, monto, fecha).
