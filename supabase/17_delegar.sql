-- Delegar visitas a otro piletero y pasar clientes de un piletero a otro.
-- visitas.piletero_id: si está cargado, esa visita la hace ese piletero (si no, el piletero del cliente).
alter table public.visitas add column if not exists piletero_id uuid references public.perfiles(id) on delete set null;
create index if not exists visitas_piletero on public.visitas (piletero_id) where piletero_id is not null;

-- El piletero que tiene una visita delegada puede ver los datos de ese cliente (solo lectura).
create or replace function public.delegado_en(p_cliente uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from visitas where cliente_id = p_cliente and piletero_id = auth.uid());
$$;
revoke execute on function public.delegado_en(uuid) from public, anon;
grant execute on function public.delegado_en(uuid) to authenticated;

drop policy if exists delegadas on public.clientes;
create policy delegadas on public.clientes for select to authenticated using (delegado_en(id));

-- Visitas: las ve también a quien se las delegaron. Crear o cambiar sigue siendo del dueño del cliente o coordinador.
drop policy if exists visitas on public.visitas;
create policy visitas on public.visitas for all to authenticated
  using (es_gestor() or piletero_id = auth.uid() or exists (select 1 from clientes c where c.id = visitas.cliente_id and c.piletero_id = auth.uid()))
  with check (es_gestor() or exists (select 1 from clientes c where c.id = visitas.cliente_id and c.piletero_id = auth.uid()));

-- Pasar una visita (p_fecha = solo ese día de una visita que se repite; null = todas). p_piletero null = devolverla al piletero del cliente.
create or replace function public.delegar_visita(p_visita uuid, p_piletero uuid, p_fecha date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v visitas; c clientes; yo text; nueva uuid; para uuid := p_piletero; cuando text;
begin
  select * into v from visitas where id = p_visita;
  if not found then raise exception 'La visita no existe'; end if;
  select * into c from clientes where id = v.cliente_id;
  if not (es_gestor() or c.piletero_id = auth.uid() or v.piletero_id = auth.uid()) then raise exception 'No podés pasar esta visita'; end if;
  if para is not null and not exists (select 1 from perfiles where id = para and activo) then raise exception 'Ese piletero no está habilitado'; end if;
  if para = c.piletero_id then para := null; end if;
  if p_fecha is not null and v.repetir in ('semanal', 'quincenal') then
    update visitas set omitir = array_append(coalesce(omitir, '{}'), p_fecha::text) where id = v.id;
    insert into visitas (cliente_id, fecha, hora, repetir, piletero_id) values (v.cliente_id, p_fecha, v.hora, 'no', para) returning id into nueva;
    cuando := 'el ' || to_char(p_fecha, 'DD/MM');
  else
    update visitas set piletero_id = para where id = v.id; nueva := v.id;
    cuando := case v.repetir when 'semanal' then 'todas las semanas' when 'quincenal' then 'cada 15 días' else 'el ' || to_char(v.fecha, 'DD/MM') end;
  end if;
  select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
  if coalesce(para, c.piletero_id) is distinct from auth.uid() then
    perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', coalesce(para, c.piletero_id), 'title', '📅 ' || coalesce(yo, 'El equipo') || ' te pasó una visita',
      'body', c.nombre || ' · ' || cuando || coalesce(' · ' || to_char(v.hora, 'HH24:MI'), ''), 'url', 'index.html', 'tag', 'traspaso-' || nueva));
  end if;
  return nueva;
end $$;

-- Pasar un cliente a otro piletero (el dueño actual o un coordinador).
create or replace function public.pasar_cliente(p_cliente uuid, p_piletero uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c clientes; yo text;
begin
  select * into c from clientes where id = p_cliente;
  if not found then raise exception 'El cliente no existe'; end if;
  if not (es_gestor() or c.piletero_id = auth.uid()) then raise exception 'Solo el piletero del cliente o un coordinador puede pasarlo'; end if;
  if not exists (select 1 from perfiles where id = p_piletero and activo) then raise exception 'Ese piletero no está habilitado'; end if;
  update clientes set piletero_id = p_piletero where id = p_cliente;
  update visitas set piletero_id = null where cliente_id = p_cliente and piletero_id = p_piletero;
  select split_part(nombre, ' ', 1) into yo from perfiles where id = auth.uid();
  if p_piletero <> auth.uid() then
    perform llamar_push(jsonb_build_object('tabla', 'traspaso', 'para', p_piletero, 'title', '👤 ' || coalesce(yo, 'El equipo') || ' te pasó un cliente',
      'body', c.nombre || ' · ' || coalesce(c.direccion, '') || '. Ya está en tus clientes y en tu calendario.', 'url', 'index.html', 'tag', 'cliente-' || c.id));
  end if;
end $$;

revoke execute on function public.delegar_visita(uuid, uuid, date), public.pasar_cliente(uuid, uuid) from public, anon;
grant execute on function public.delegar_visita(uuid, uuid, date), public.pasar_cliente(uuid, uuid) to authenticated;
