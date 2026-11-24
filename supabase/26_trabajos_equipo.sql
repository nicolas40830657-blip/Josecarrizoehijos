-- Trabajos: 20% fijo para la empresa; el responsable (quien toma el trabajo, ej. José) y cada empleado cobran lo que se carga a mano.
alter table public.trabajos add column if not exists responsable_id uuid references public.perfiles(id) on delete set null;
alter table public.trabajos add column if not exists resp_pago numeric check (resp_pago is null or resp_pago >= 0);
alter table public.trabajos add column if not exists equipo jsonb not null default '[]'::jsonb check (jsonb_typeof(equipo) = 'array');

-- Pasar los trabajos que ya existían al nuevo esquema
update public.trabajos set equipo = jsonb_build_array(jsonb_build_object('id', piletero_id, 'pago', coalesce(pago, 0)))
 where equipo = '[]'::jsonb and piletero_id is not null;
update public.trabajos set responsable_id = creado_por where responsable_id is null;
update public.trabajos set empresa = round(presupuesto * 0.2);

-- ¿Participa este usuario del trabajo? (responsable o empleado)
create or replace function public.participa_trabajo(t public.trabajos, u uuid)
returns boolean language sql immutable as $$
  select t.responsable_id = u or t.piletero_id = u or t.equipo @> jsonb_build_array(jsonb_build_object('id', u::text));
$$;

-- Lo que cobra un usuario en un trabajo
create or replace function public.pago_en_trabajo(t public.trabajos, u uuid)
returns numeric language sql immutable as $$
  select coalesce(case when t.responsable_id = u then t.resp_pago end, 0)
       + coalesce((select sum((e->>'pago')::numeric) from jsonb_array_elements(t.equipo) e where e->>'id' = u::text), 0);
$$;

-- Lo que ve cada uno de sus trabajos: sin el presupuesto, solo lo que cobra él
create or replace function public.mis_trabajos(p_desde date default null)
returns setof json language sql stable security definer set search_path = public as $$
  select json_build_object('id', t.id, 'tipo', t.tipo, 'titulo', t.titulo, 'cliente_id', t.cliente_id, 'nombre', coalesce(t.nombre, c.nombre), 'direccion', coalesce(t.direccion, c.direccion),
         'lat', coalesce(t.lat, c.lat), 'lng', coalesce(t.lng, c.lng), 'fecha', t.fecha, 'hora', t.hora, 'dias', t.dias, 'piletero_id', t.piletero_id,
         'responsable_id', t.responsable_id, 'equipo', (select coalesce(json_agg(json_build_object('id', e->>'id')), '[]'::json) from jsonb_array_elements(t.equipo) e),
         'mio', pago_en_trabajo(t, auth.uid()), 'pago', pago_en_trabajo(t, auth.uid()),
         'estado', t.estado, 'notas', t.notas, 'terminado', t.terminado, 'pagado', t.pagado)
    from trabajos t left join clientes c on c.id = t.cliente_id
   where es_equipo() and participa_trabajo(t, auth.uid()) and t.estado <> 'cancelado'
     and t.fecha + t.dias > coalesce(p_desde, current_date - 60)
   order by t.fecha;
$$;

create or replace function public.terminar_trabajo(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t trabajos; g uuid; yo text;
begin
  select * into t from trabajos where id = p_id for update;
  if not found then raise exception 'El trabajo no existe'; end if;
  if not (es_gestor() or participa_trabajo(t, auth.uid())) then raise exception 'Este trabajo no es tuyo'; end if;
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

-- Aviso a cada empleado (y al responsable) cuando lo suman a un trabajo o le cambian la fecha
create or replace function public.avisar_trabajo()
returns trigger language plpgsql security definer set search_path = public as $$
declare yo text; lugar text; u uuid; nuevos uuid[]; viejos uuid[] := '{}'; cambio boolean;
begin
  if new.estado <> 'programado' then return new; end if;
  select array_agg(distinct x) into nuevos from (
    select (e->>'id')::uuid x from jsonb_array_elements(new.equipo) e where e->>'id' is not null
    union select new.responsable_id union select new.piletero_id) s where x is not null;
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(distinct x), '{}') into viejos from (
      select (e->>'id')::uuid x from jsonb_array_elements(old.equipo) e where e->>'id' is not null
      union select old.responsable_id union select old.piletero_id) s where x is not null;
  end if;
  cambio := tg_op = 'UPDATE' and (new.fecha <> old.fecha or new.dias <> old.dias);
  select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
  lugar := coalesce(new.nombre, (select nombre from clientes where id = new.cliente_id), new.direccion, '');
  foreach u in array coalesce(nuevos, '{}') loop
    continue when u = auth.uid() or (not cambio and u = any(viejos));
    perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', u,
      'title', '🛠️ ' || coalesce(yo, 'El equipo') || case when cambio and u = any(viejos) then ' cambió la fecha de un trabajo' else ' te programó un trabajo' end,
      'body', coalesce(new.titulo, initcap(new.tipo)) || ' · ' || lugar || ' · desde el ' || to_char(new.fecha, 'DD/MM') || case when new.dias > 1 then ' (' || new.dias || ' días)' else '' end
              || case when pago_en_trabajo(new, u) > 0 then ' · cobrás $' || to_char(pago_en_trabajo(new, u), 'FM999G999G999') else '' end,
      'url', 'index.html#trabajo=' || new.id, 'tag', 'trabajo-' || new.id));
  end loop;
  return new;
end $$;
revoke execute on function public.avisar_trabajo() from public, anon, authenticated;
drop trigger if exists push_trabajo on public.trabajos;
create trigger push_trabajo after insert or update of piletero_id, fecha, dias, equipo, responsable_id on public.trabajos for each row execute function avisar_trabajo();
