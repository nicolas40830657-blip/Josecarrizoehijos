-- ════════════════════════════════════════════════════════════════════
--  Cuentas del equipo con aprobación
--  Antes, cualquiera que se registraba quedaba como piletero. Ahora una
--  cuenta nueva queda "pendiente" hasta que un coordinador o la
--  administración la habilita. Las cuentas existentes quedan activas.
--  La seguridad ya no depende de user_metadata (que el usuario puede editar).
-- ════════════════════════════════════════════════════════════════════
alter table public.perfiles add column if not exists activo boolean not null default false;
do $$ begin
  if not exists (select 1 from perfiles where activo) then update perfiles set activo = true; end if;
end $$;

create or replace function public.proteger_rol() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null then
    if tg_op = 'INSERT' then
      new.rol := 'piletero'; new.porc_productos := 0; new.activo := false;
    else
      new.rol := old.rol;
      if not es_gestor() then new.porc_productos := old.porc_productos; new.activo := old.activo; end if;
    end if;
  end if;
  return new;
end $$;

-- Equipo = tiene perfil habilitado y no es una cuenta vinculada como cliente
create or replace function public.es_equipo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and activo)
     and not exists (select 1 from clientes where usuario_id = auth.uid());
$$;

-- Los gestores también tienen que estar habilitados
create or replace function public.es_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and activo and rol in ('coordinador','administrador'))
$$;
create or replace function public.es_coordinador() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and activo and rol = 'coordinador')
$$;

-- perfiles: alta solo del propio perfil y nunca desde una cuenta de cliente
drop policy if exists sin_clientes_alta on public.perfiles;
create policy sin_clientes_alta on public.perfiles as restrictive for insert to public
  with check (id = auth.uid() and mi_cliente_id() is null);

-- Funciones internas: no se pueden llamar sin iniciar sesión
revoke execute on function public.es_equipo(), public.atiende(uuid), public.mi_cliente_id(),
  public.es_gestor(), public.es_coordinador(), public.pagar(numeric) from anon, public;
grant execute on function public.es_equipo(), public.atiende(uuid), public.mi_cliente_id(),
  public.es_gestor(), public.es_coordinador(), public.pagar(numeric) to authenticated;
