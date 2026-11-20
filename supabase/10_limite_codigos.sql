-- Límite de intentos con el código de acceso: 10 códigos equivocados por hora por cuenta.
-- Evita que alguien pruebe códigos al azar hasta dar con la pileta de otro.
create table if not exists public.intentos_codigo (
  id bigint generated always as identity primary key,
  usuario_id uuid not null,
  creado timestamptz not null default now()
);
create index if not exists intentos_codigo_usuario on public.intentos_codigo (usuario_id, creado desc);
alter table public.intentos_codigo enable row level security;   -- sin políticas: solo la usa la función
revoke all on public.intentos_codigo from anon, authenticated;

-- Devuelve el id del cliente si el código es correcto, o null si no (y cuenta el intento).
-- No usa "raise" en el código equivocado para que el intento quede guardado.
create or replace function public.vincular_pileta(p_codigo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; dueno uuid; fallos int;
begin
  if auth.uid() is null then raise exception 'Tenés que iniciar sesión'; end if;
  if es_equipo() then raise exception 'Esta es una cuenta del equipo. Creá una cuenta de cliente aparte.'; end if;
  select count(*) into fallos from intentos_codigo where usuario_id = auth.uid() and creado > now() - interval '1 hour';
  if fallos >= 10 then raise exception 'Probaste demasiados códigos. Esperá una hora o pedile el código a tu piletero.'; end if;
  select id, usuario_id into cid, dueno from clientes where codigo = upper(trim(coalesce(p_codigo, '')));
  if cid is null or (dueno is not null and dueno <> auth.uid()) then
    insert into intentos_codigo (usuario_id) values (auth.uid());
    delete from intentos_codigo where creado < now() - interval '1 day';
    return null;
  end if;
  update clientes set usuario_id = auth.uid() where id = cid;
  return cid;
end $$;
