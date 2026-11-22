-- Objetivos mensuales: cada piletero configura el suyo (visitas y $ de visitas); el de la empresa es la suma de todos.
alter table public.perfiles add column if not exists obj_visitas int check (obj_visitas is null or obj_visitas between 0 and 2000);
alter table public.perfiles add column if not exists obj_monto numeric check (obj_monto is null or obj_monto >= 0);

-- Progreso de la empresa en un mes (solo totales por día, sin detalle de clientes).
-- Los pileteros ven visitas; los coordinadores también ven la plata y el detalle por piletero.
create or replace function public.progreso_empresa(p_mes date default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare d0 date := date_trunc('month', coalesce(p_mes, (now() at time zone 'America/Argentina/Buenos_Aires')::date))::date;
        d1 date := (date_trunc('month', coalesce(p_mes, (now() at time zone 'America/Argentina/Buenos_Aires')::date)) + interval '1 month')::date;
        g boolean := es_gestor();
begin
  if not es_equipo() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'obj_visitas', (select coalesce(sum(obj_visitas), 0) from perfiles where activo and coalesce(rol, '') <> 'administrador'),
    'obj_monto', case when g then (select coalesce(sum(obj_monto), 0) from perfiles where activo and coalesce(rol, '') <> 'administrador') end,
    'dias', coalesce((select json_agg(x order by x.dia) from (
               select extract(day from fecha)::int as dia, count(*) as n, case when g then sum(coalesce(valor, 0)) end as monto
                 from realizadas where fecha >= d0 and fecha < d1 group by 1) x), '[]'::json),
    'pileteros', case when g then coalesce((select json_agg(y order by y.nombre) from (
               select p.id, p.nombre, p.color, p.obj_visitas, p.obj_monto,
                      (select count(*) from realizadas r where r.piletero_id = p.id and r.fecha >= d0 and r.fecha < d1) as n,
                      (select coalesce(sum(valor), 0) from realizadas r where r.piletero_id = p.id and r.fecha >= d0 and r.fecha < d1) as monto
                 from perfiles p where p.activo and coalesce(p.rol, '') <> 'administrador') y), '[]'::json) end
  );
end $$;
revoke execute on function public.progreso_empresa(date) from public, anon;
grant execute on function public.progreso_empresa(date) to authenticated;
