-- Trabajos fuera del mantenimiento (limpieza de pileta, pintura, reparación…): los programan coordinadores/administración.
create table if not exists public.trabajos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null default 'limpieza' check (tipo in ('limpieza', 'pintura', 'reparacion', 'instalacion', 'otro')),
  titulo text check (titulo is null or length(titulo) <= 200),
  cliente_id uuid references public.clientes(id) on delete set null,
  nombre text check (nombre is null or length(nombre) <= 120),
  direccion text check (direccion is null or length(direccion) <= 200),
  lat double precision, lng double precision,
  fecha date not null,
  hora time,
  dias int not null default 1 check (dias between 1 and 60),
  presupuesto numeric not null default 0 check (presupuesto >= 0),
  pago numeric not null default 0 check (pago >= 0),
  piletero_id uuid references public.perfiles(id) on delete set null,
  estado text not null default 'programado' check (estado in ('programado', 'terminado', 'pagado', 'cancelado')),
  cobrado boolean not null default false,
  notas text check (notas is null or length(notas) <= 1000),
  creado_por uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado timestamptz not null default now(),
  terminado timestamptz,
  pagado timestamptz
);
create index if not exists trabajos_fecha on public.trabajos (fecha);
create index if not exists trabajos_piletero on public.trabajos (piletero_id);
alter table public.trabajos enable row level security;
drop policy if exists solo_equipo on public.trabajos;
create policy solo_equipo on public.trabajos as restrictive for all to authenticated using (es_equipo()) with check (es_equipo());
-- La tabla completa (con el presupuesto) solo la ven y editan coordinadores/administración
drop policy if exists gestores on public.trabajos;
create policy gestores on public.trabajos for all to authenticated using (es_gestor()) with check (es_gestor());
revoke all on public.trabajos from anon;
grant select, insert, update, delete on public.trabajos to authenticated;

-- Los pileteros ven sus trabajos sin el presupuesto (solo lo que cobran ellos)
create or replace function public.mis_trabajos(p_desde date default null)
returns setof json language sql stable security definer set search_path = public as $$
  select json_build_object('id', t.id, 'tipo', t.tipo, 'titulo', t.titulo, 'cliente_id', t.cliente_id, 'nombre', coalesce(t.nombre, c.nombre), 'direccion', coalesce(t.direccion, c.direccion),
         'lat', coalesce(t.lat, c.lat), 'lng', coalesce(t.lng, c.lng), 'fecha', t.fecha, 'hora', t.hora, 'dias', t.dias, 'pago', t.pago, 'piletero_id', t.piletero_id,
         'estado', t.estado, 'notas', t.notas, 'terminado', t.terminado, 'pagado', t.pagado)
    from trabajos t left join clientes c on c.id = t.cliente_id
   where es_equipo() and t.piletero_id = auth.uid() and t.estado <> 'cancelado'
     and t.fecha + t.dias > coalesce(p_desde, current_date - 60)
   order by t.fecha;
$$;

-- El piletero avisa que terminó
create or replace function public.terminar_trabajo(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t trabajos; g uuid; yo text;
begin
  select * into t from trabajos where id = p_id for update;
  if not found then raise exception 'El trabajo no existe'; end if;
  if not (es_gestor() or t.piletero_id = auth.uid()) then raise exception 'Este trabajo no es tuyo'; end if;
  if t.estado <> 'programado' then raise exception 'El trabajo ya está %', t.estado; end if;
  update trabajos set estado = 'terminado', terminado = now() where id = p_id;
  if not es_gestor() then
    select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
    for g in select id from perfiles where activo and rol in ('coordinador', 'administrador') loop
      perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', g, 'title', '✅ ' || coalesce(yo, 'Un piletero') || ' terminó un trabajo',
        'body', coalesce(t.titulo, t.tipo) || ' · ' || coalesce(t.nombre, (select nombre from clientes where id = t.cliente_id), '') || '. Ya lo podés pagar.', 'url', 'index.html#trabajo=' || p_id, 'tag', 'trabajo-' || p_id));
    end loop;
  end if;
end $$;

-- Aviso al piletero cuando le asignan (o le cambian la fecha de) un trabajo
create or replace function public.avisar_trabajo()
returns trigger language plpgsql security definer set search_path = public as $$
declare yo text; lugar text;
begin
  if new.piletero_id is null or new.piletero_id = auth.uid() or new.estado <> 'programado' then return new; end if;
  if tg_op = 'UPDATE' and new.piletero_id is not distinct from old.piletero_id and new.fecha = old.fecha and new.dias = old.dias then return new; end if;
  select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
  lugar := coalesce(new.nombre, (select nombre from clientes where id = new.cliente_id), new.direccion, '');
  perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', new.piletero_id,
    'title', '🛠️ ' || coalesce(yo, 'El equipo') || ' te programó un trabajo',
    'body', coalesce(new.titulo, initcap(new.tipo)) || ' · ' || lugar || ' · desde el ' || to_char(new.fecha, 'DD/MM') || case when new.dias > 1 then ' (' || new.dias || ' días)' else '' end || case when new.pago > 0 then ' · cobrás $' || to_char(new.pago, 'FM999G999G999') else '' end,
    'url', 'index.html#trabajo=' || new.id, 'tag', 'trabajo-' || new.id));
  return new;
end $$;
revoke execute on function public.avisar_trabajo() from public, anon, authenticated;
drop trigger if exists push_trabajo on public.trabajos;
create trigger push_trabajo after insert or update of piletero_id, fecha, dias on public.trabajos for each row execute function avisar_trabajo();

revoke execute on function public.mis_trabajos(date), public.terminar_trabajo(uuid) from public, anon;
grant execute on function public.mis_trabajos(date), public.terminar_trabajo(uuid) to authenticated;
