-- Instituciones (edificios con consorcio) que contratan a través de una administración, con abono mensual por edificio.
create table if not exists public.administraciones (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (length(nombre) between 1 and 120),
  contacto text check (contacto is null or length(contacto) <= 120),
  telefono text check (telefono is null or length(telefono) <= 40),
  email text check (email is null or length(email) <= 120),
  notas text check (notas is null or length(notas) <= 1000),
  codigo text not null unique default ('A' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6))),
  usuario_id uuid references auth.users(id) on delete set null,
  creado timestamptz not null default now()
);
alter table public.administraciones enable row level security;
drop policy if exists solo_equipo on public.administraciones;
create policy solo_equipo on public.administraciones as restrictive for all to authenticated using (es_equipo()) with check (es_equipo());
drop policy if exists equipo_lee on public.administraciones;
create policy equipo_lee on public.administraciones for select to authenticated using (es_equipo());
drop policy if exists gestor_escribe on public.administraciones;
create policy gestor_escribe on public.administraciones for all to authenticated using (es_gestor()) with check (es_gestor());
revoke all on public.administraciones from anon;
grant select, insert, update, delete on public.administraciones to authenticated;

alter table public.clientes add column if not exists tipo text not null default 'particular' check (tipo in ('particular', 'institucion'));
alter table public.clientes add column if not exists administracion_id uuid references public.administraciones(id) on delete set null;
alter table public.clientes add column if not exists abono numeric check (abono is null or abono >= 0);
alter table public.clientes add column if not exists visitas_semana int check (visitas_semana is null or visitas_semana between 1 and 7);
create index if not exists clientes_admin on public.clientes (administracion_id) where administracion_id is not null;

-- Las visitas de un edificio con abono: valen la parte proporcional del abono y la empresa le paga al piletero (no al revés)
alter table public.realizadas add column if not exists abono boolean not null default false;
create or replace function public.valor_abono(p_abono numeric, p_vs int)
returns numeric language sql immutable as $$ select case when coalesce(p_abono, 0) > 0 then round(p_abono / (greatest(coalesce(p_vs, 1), 1) * 52.0 / 12)) else 0 end $$;
create or replace function public.marcar_abono_realizada()
returns trigger language plpgsql security definer set search_path = public as $$
declare c clientes;
begin
  select * into c from clientes where id = new.cliente_id;
  if c.tipo = 'institucion' and coalesce(c.abono, 0) > 0 then
    new.abono := true; new.valor := valor_abono(c.abono, c.visitas_semana);
  else new.abono := false; end if;
  return new;
end $$;
drop trigger if exists abono_realizada on public.realizadas;
create trigger abono_realizada before insert on public.realizadas for each row execute function marcar_abono_realizada();

-- Devolver a la empresa: solo las visitas comunes (las de abono las cobra la empresa)
create or replace function public.pagar(empresa numeric default 0.3)
returns void language plpgsql security definer set search_path = public as $$
declare v_monto numeric; v_n int; v_id uuid;
begin
  select coalesce(sum(valor), 0) * 0.3, count(*) into v_monto, v_n
    from realizadas where piletero_id = auth.uid() and pago_id is null and not abono;
  if v_n = 0 then return; end if;
  insert into pagos (piletero_id, monto, visitas) values (auth.uid(), v_monto, v_n) returning id into v_id;
  update realizadas set pago_id = v_id where piletero_id = auth.uid() and pago_id is null and not abono;
end $$;

-- Cuenta mensual de cada administración (pagada o pendiente)
create table if not exists public.abono_pagos (
  id uuid primary key default gen_random_uuid(),
  administracion_id uuid not null references public.administraciones(id) on delete cascade,
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  monto numeric not null default 0,
  pagado boolean not null default true,
  fecha date not null default (now() at time zone 'America/Argentina/Buenos_Aires')::date,
  creado timestamptz not null default now(),
  unique (administracion_id, mes)
);
alter table public.abono_pagos enable row level security;
drop policy if exists solo_equipo on public.abono_pagos;
create policy solo_equipo on public.abono_pagos as restrictive for all to authenticated using (es_equipo()) with check (es_equipo());
drop policy if exists gestores on public.abono_pagos;
create policy gestores on public.abono_pagos for all to authenticated using (es_gestor()) with check (es_gestor());
revoke all on public.abono_pagos from anon;
grant select, insert, update, delete on public.abono_pagos to authenticated;

-- La administración elige qué edificio está mirando en su app
create table if not exists public.admin_sel (
  usuario_id uuid primary key references auth.users(id) on delete cascade,
  cliente_id uuid references public.clientes(id) on delete cascade
);
alter table public.admin_sel enable row level security;
revoke all on public.admin_sel from anon, authenticated;

create or replace function public.mi_administracion_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from administraciones where usuario_id = auth.uid() order by creado limit 1;
$$;

-- El "cliente actual": el propio, o el edificio que la administración está mirando
create or replace function public.mi_cliente_id()
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select id from clientes where usuario_id = auth.uid() order by creado limit 1),
    (select s.cliente_id from admin_sel s join clientes c on c.id = s.cliente_id
      where s.usuario_id = auth.uid() and c.administracion_id = mi_administracion_id()),
    (select id from clientes where administracion_id = mi_administracion_id() order by nombre limit 1));
$$;

create or replace function public.elegir_edificio(p_cliente uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if mi_administracion_id() is null or not exists (select 1 from clientes where id = p_cliente and administracion_id = mi_administracion_id()) then
    raise exception 'Ese edificio no es de tu administración';
  end if;
  insert into admin_sel (usuario_id, cliente_id) values (auth.uid(), p_cliente)
    on conflict (usuario_id) do update set cliente_id = excluded.cliente_id;
end $$;

-- Todo lo que ve la administración: sus edificios, la cuenta del mes y los datos para transferir
create or replace function public.mi_administracion()
returns json language plpgsql stable security definer set search_path = public as $$
declare a administraciones; v_mes text := to_char((now() at time zone 'America/Argentina/Buenos_Aires')::date, 'YYYY-MM'); pago jsonb;
begin
  select * into a from administraciones where id = mi_administracion_id();
  if a.id is null then return null; end if;
  select valor into pago from ajustes where clave = 'pago_empresa';
  return json_build_object(
    'id', a.id, 'nombre', a.nombre, 'sel', mi_cliente_id(), 'mes', v_mes,
    'edificios', coalesce((select json_agg(x order by x.nombre) from (
       select c.id, c.nombre, c.direccion, c.abono, c.visitas_semana, p.nombre as piletero,
              (select max(r.fecha) from realizadas r where r.cliente_id = c.id) as ultima,
              (select count(*) from realizadas r where r.cliente_id = c.id and to_char(r.fecha, 'YYYY-MM') = v_mes) as visitas_mes
         from clientes c left join perfiles p on p.id = c.piletero_id where c.administracion_id = a.id) x), '[]'::json),
    'total', (select coalesce(sum(c2.abono), 0) from clientes c2 where c2.administracion_id = a.id),
    'pagos', coalesce((select json_agg(y order by y.mes desc) from (select ap.mes, ap.monto, ap.pagado, ap.fecha from abono_pagos ap where ap.administracion_id = a.id order by ap.mes desc limit 12) y), '[]'::json),
    'pago_empresa', pago);
end $$;

-- Vincular: acepta el código de un cliente o el de una administración
create or replace function public.vincular_pileta(p_codigo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; dueno uuid; fallos int; aid uuid; cod text := upper(trim(coalesce(p_codigo, '')));
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  if es_equipo() then raise exception 'Esta es una cuenta del equipo. Creá una cuenta de cliente aparte.'; end if;
  select count(*) into fallos from intentos_codigo where usuario_id = auth.uid() and creado > now() - interval '1 hour';
  if fallos >= 10 then raise exception 'Probaste demasiados códigos. Esperá una hora o pedile el código a tu piletero.'; end if;
  select id, usuario_id into aid, dueno from administraciones where codigo = cod;
  if aid is not null and (dueno is null or dueno = auth.uid()) then
    update administraciones set usuario_id = auth.uid() where id = aid;
    return coalesce((select id from clientes where administracion_id = aid order by nombre limit 1), aid);
  end if;
  select id, usuario_id into cid, dueno from clientes where codigo = cod;
  if cid is null or (dueno is not null and dueno <> auth.uid()) then
    insert into intentos_codigo (usuario_id) values (auth.uid());
    delete from intentos_codigo where creado < now() - interval '1 day';
    return null;
  end if;
  update clientes set usuario_id = auth.uid() where id = cid;
  return cid;
end $$;

revoke execute on function public.mi_administracion_id(), public.elegir_edificio(uuid), public.mi_administracion() from public, anon;
grant execute on function public.mi_administracion_id(), public.elegir_edificio(uuid), public.mi_administracion() to authenticated;
revoke execute on function public.marcar_abono_realizada() from public, anon, authenticated;

-- mi_pileta: ahora usa el "cliente actual" (sirve para clientes y para administraciones) y trae los datos del abono
create or replace function public.mi_pileta()
returns json language sql stable security definer set search_path = public as $$
 select json_build_object(
  'cliente', json_build_object('id', c.id, 'nombre', c.nombre, 'direccion', c.direccion, 'telefono', c.telefono, 'valor_visita', c.valor_visita, 'frecuencia', c.frecuencia, 'dia', c.dia, 'ref', c.ref,
                               'tipo', c.tipo, 'abono', c.abono, 'visitas_semana', c.visitas_semana),
  'piletero', (select json_build_object('id', p.id, 'nombre', p.nombre, 'foto', p.foto, 'color', p.color, 'alias', p.pago_alias, 'cbu', p.pago_cbu, 'titular', p.pago_titular, 'banco', p.pago_banco) from perfiles p where p.id = c.piletero_id),
  'visitas', coalesce((select json_agg(json_build_object('fecha', v.fecha, 'hora', v.hora, 'repetir', v.repetir, 'omitir', v.omitir)) from visitas v where v.cliente_id = c.id), '[]'::json),
  'realizadas', coalesce((select json_agg(x) from ( select r.id, r.fecha, r.valor, r.nota, r.productos, p.nombre as piletero from realizadas r left join perfiles p on p.id = r.piletero_id where r.cliente_id = c.id order by r.fecha desc limit 60) x), '[]'::json),
  'ventas', coalesce((select json_agg(y) from ( select s.id, s.fecha, s.nombre, s.cantidad, s.total, s.cobrado from ventas s where s.cliente_id = c.id and not coalesce(s.anulada, false) order by s.fecha desc, s.creado desc limit 40) y), '[]'::json),
  'catalogo', catalogo(),
  'recomendaciones', coalesce((select json_agg(w) from ( select r.id, r.tipo as t, r.item_id as id_item, r.cantidad, r.nota, r.creado, coalesce(pr.nombre, k.nombre) as nombre, coalesce(pr.precio, k.precio) as precio from recomendaciones r left join productos pr on r.tipo = 'p' and pr.id = r.item_id left join kits k on r.tipo = 'k' and k.id = r.item_id where r.cliente_id = c.id and r.estado = 'activa' and coalesce(pr.id, k.id) is not null order by r.creado desc) w), '[]'::json),
  'pedidos', coalesce((select json_agg(q) from ( select id, items, total, pago, nota, estado, creado from pedidos where cliente_id = c.id order by creado desc limit 20) q), '[]'::json),
  'premios', coalesce((select json_agg(pm) from ( select pz.id, pz.texto, pz.estado, pz.creado, split_part(rc.nombre, ' ', 1) as referido from premios pz join clientes rc on rc.id = pz.referido_id where pz.cliente_id = c.id order by pz.creado desc limit 20) pm), '[]'::json),
  'premio_recomendar', (select case when (valor->>'activo')::boolean then valor->>'texto' end from ajustes where clave = 'premio_recomendar'))
 from clientes c where c.id = mi_cliente_id();
$$;
